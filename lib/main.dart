import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'services/license_service.dart';
import 'services/sound_service.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'widgets/cyber_page_route.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const LocalVPNApp());
}

class LocalVPNApp extends StatelessWidget {
  const LocalVPNApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalVPN',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  final LicenseService _licenseService = LicenseService();
  late AnimationController _animController;
  late AnimationController _scanlineController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _scanlineAnimation;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    // Scan-line overlay animation
    _scanlineController = AnimationController(
      duration: const Duration(milliseconds: 3000),
      vsync: this,
    )..repeat();

    _scanlineAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(
        parent: _scanlineController,
        curve: Curves.linear,
      ),
    );

    _animController.forward();
    _initAll();
  }

  Future<void> _initAll() async {
    // Initialize sound system and license in parallel
    await Future.wait([
      SoundService().init(),
      _licenseService.init(),
    ]);

    // Play boot sound after init
    SoundService().play(SfxType.boot);

    // Wait minimum splash time
    await Future.delayed(const Duration(milliseconds: 2000));

    if (!mounted) return;

    // Free model: always allow entry. If no license found, set free status.
    final state = _licenseService.state;
    if (!state.isValid) {
      _licenseService.setFreeMode();
    }

    Navigator.of(context).pushReplacement(
      CyberPageRoute(
        builder: (_) => HomeScreen(licenseService: _licenseService),
      ),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    _scanlineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Stack(
          children: [
            // Main content
            Center(
              child: AnimatedBuilder(
                animation: _animController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _fadeAnimation.value,
                    child: Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Logo with neon glow pulse
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.3),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Image.asset(
                                'assets/logo.webp',
                                fit: BoxFit.cover,
                              ),
                            ),
                          )
                              .animate(
                                  onPlay: (c) => c.repeat(reverse: true))
                              .shimmer(
                                duration: 2000.ms,
                                color: AppColors.primary.withValues(alpha: 0.3),
                              ),
                          const SizedBox(height: 24),
                          const Text(
                            'LocalVPN',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Virtual LAN over Internet',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textMuted,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 40),
                          // Loading dots instead of spinner
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(
                              3,
                              (i) => Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary,
                                ),
                              )
                                  .animate(
                                      onPlay: (c) =>
                                          c.repeat(reverse: true))
                                  .fadeIn(
                                    delay: (i * 200).ms,
                                    duration: 600.ms,
                                  )
                                  .scale(
                                    begin: const Offset(0.5, 0.5),
                                    end: const Offset(1.2, 1.2),
                                    delay: (i * 200).ms,
                                    duration: 600.ms,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // Scan-line overlay effect
            AnimatedBuilder(
              animation: _scanlineAnimation,
              builder: (context, _) {
                return IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          AppColors.primary.withValues(alpha: 0.03),
                          Colors.transparent,
                          Colors.transparent,
                        ],
                        stops: [
                          0.0,
                          (_scanlineAnimation.value - 0.05).clamp(0.0, 1.0),
                          _scanlineAnimation.value.clamp(0.0, 1.0),
                          (_scanlineAnimation.value + 0.05).clamp(0.0, 1.0),
                          1.0,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
