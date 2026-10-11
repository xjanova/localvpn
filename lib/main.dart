import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'dev/launch_options.dart';
import 'dev/shot_harness.dart';
import 'dev/tun_selftest.dart';
import 'platform/platform_info.dart';
import 'screens/shell/app_shell.dart';
import 'services/license_service.dart';
import 'services/sound_service.dart';
import 'widgets/m3/m3.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final selfTest = args.indexOf('--selftest-tun');
  if (isWindows && selfTest >= 0 && selfTest + 1 < args.length) {
    runApp(const SizedBox.shrink());
    await runTunSelfTest(args[selfTest + 1]);
    return;
  }

  final options = LaunchOptions.parse(args);

  if (isDesktop) {
    // sqflite has no desktop plugin; use the FFI build of SQLite. Before
    // anything reads settings: they live in SQLite (AppStore).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final theme = M3ThemeController.instance;
  await theme.load();
  if (options.theme != null) theme.force(options.theme == 'night');

  if (isWindows) {
    await windowManager.ensureInitialized();
    final win = WindowOptions(
      size: options.size ?? const Size(1360, 860),
      // Screenshot runs may emulate a phone-sized window.
      minimumSize: options.isShot ? null : const Size(960, 640),
      center: !options.isShot,
      title: 'LocalVPN',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: const Color(0xFF050A1C),
    );
    unawaited(windowManager.waitUntilReadyToShow(win, () async {
      if (options.isShot) {
        // Screenshot runs render off-screen and never take focus.
        await windowManager.setPosition(const Offset(-32000, -32000));
        await windowManager.show(inactive: true);
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    }));
  } else {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF050A1C),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  runApp(LocalVPNApp(options: options));
}

class LocalVPNApp extends StatelessWidget {
  final LaunchOptions options;

  const LocalVPNApp({super.key, this.options = const LaunchOptions()});

  @override
  Widget build(BuildContext context) {
    final theme = M3ThemeController.instance;
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        Widget app = MaterialApp(
          title: 'LocalVPN',
          debugShowCheckedModeBanner: false,
          theme: theme.theme,
          home: options.isShot
              ? ShotHarness(options: options)
              : const SplashScreen(),
        );
        if (options.isShot) app = ShotHarness.wrap(app);
        return app;
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final LicenseService _licenseService = LicenseService();
  String _status = 'กำลังเตรียมระบบ…';

  /// First launch without internet: the device must register once.
  bool _needsNetwork = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    M3Icons.precache(context);
  }

  Future<void> _initAll() async {
    final minSplash = Future.delayed(const Duration(milliseconds: 1600));
    setState(() => _status = 'กำลังตรวจสอบไลเซนส์…');
    await Future.wait([
      SoundService().init(),
      _licenseService.init(),
    ]);
    SoundService().play(SfxType.boot);
    await minSplash;
    if (!mounted) return;
    _enterOrWait();
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _status = 'กำลังลงทะเบียนเครื่อง…';
    });
    await _licenseService.retryRegistration();
    if (!mounted) return;
    setState(() => _retrying = false);
    _enterOrWait();
  }

  void _enterOrWait() {
    if (_licenseService.needsOnlineRegistration) {
      setState(() {
        _needsNetwork = true;
        _status = _licenseService.state.errorMessage ??
            'เชื่อมต่ออินเทอร์เน็ตเพื่อลงทะเบียนเครื่องครั้งแรก';
      });
      return;
    }
    Navigator.of(context).pushReplacement(
      M3PageRoute(
        builder: (_) => AppShell(licenseService: _licenseService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: M3Wallpaper()),
          if (isWindows)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 38,
                child: DragToMoveArea(child: SizedBox.expand()),
              ),
            ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon3D(M3Icons.logo, size: 168, glow: p.logoGlow)
                    .animate()
                    .fadeIn(duration: 500.ms)
                    .scale(
                      begin: const Offset(0.82, 0.82),
                      duration: 700.ms,
                      curve: Curves.easeOutBack,
                    ),
                const SizedBox(height: 18),
                const _SplashWordmark()
                    .animate()
                    .fadeIn(delay: 200.ms, duration: 500.ms)
                    .slideY(begin: 0.2, end: 0),
                const SizedBox(height: 6),
                Text('VIRTUAL LAN  ·  GAME BOOST',
                        style: M3Text.eyebrow(context))
                    .animate()
                    .fadeIn(delay: 350.ms, duration: 500.ms),
                const SizedBox(height: 34),
                if (!_needsNetwork || _retrying)
                  const SizedBox(
                    width: 240,
                    child: M3ProgressBar(height: 8),
                  ),
                const SizedBox(height: 12),
                Text(_status,
                    textAlign: TextAlign.center, style: M3Text.sub(context)),
                if (_needsNetwork && !_retrying) ...[
                  const SizedBox(height: 16),
                  GlossButton(
                    label: 'ลองอีกครั้ง',
                    icon: Icons.refresh_rounded,
                    onPressed: _retry,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplashWordmark extends StatelessWidget {
  const _SplashWordmark();

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    const style = TextStyle(
      fontFamily: M3Fonts.head,
      fontSize: 46,
      fontWeight: FontWeight.w800,
      fontStyle: FontStyle.italic,
      height: 1.05,
      color: Colors.white,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShaderMask(
          shaderCallback: (r) => p.wordmark.createShader(r),
          blendMode: BlendMode.srcIn,
          child: const Text('Local', style: style),
        ),
        ShaderMask(
          shaderCallback: (r) => p.wordmarkAccent.createShader(r),
          blendMode: BlendMode.srcIn,
          child: const Text('VPN', style: style),
        ),
      ],
    );
  }
}
