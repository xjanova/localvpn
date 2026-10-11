import 'dart:ui';

/// Command-line switches (Windows desktop runs only).
///
///   LocalVPN.exe --shot D:\out\lv --pages home,boost,theme:sky,home
///                [--theme night|sky] [--size 1440x900]
///
/// --shot renders the listed pages off-screen with demo data, saves
/// `<prefix>-<theme>-<page>.png` for each and quits. It never touches the
/// network or the real licence.
class LaunchOptions {
  final String? shot;
  final List<String> pages;
  final String? theme;
  final Size? size;

  const LaunchOptions({
    this.shot,
    this.pages = const [],
    this.theme,
    this.size,
  });

  bool get isShot => shot != null;

  static LaunchOptions parse(List<String> args) {
    String? value(String name) {
      final i = args.indexOf(name);
      return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
    }

    Size? size;
    final s = value('--size');
    if (s != null) {
      final m = RegExp(r'^(\d{3,4})x(\d{3,4})$').firstMatch(s);
      if (m != null) {
        size = Size(double.parse(m.group(1)!), double.parse(m.group(2)!));
      }
    }
    final theme = value('--theme');
    return LaunchOptions(
      shot: value('--shot'),
      pages: (value('--pages') ?? 'home')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      theme: theme == 'sky' || theme == 'night' ? theme : null,
      size: size,
    );
  }
}
