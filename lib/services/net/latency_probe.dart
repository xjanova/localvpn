import 'dart:async';
import 'dart:io';

import '../../platform/windows_native.dart';

/// A run of latency probes. [rtts] holds one entry per probe in ms,
/// -1 for a probe that got no answer.
class LatencySample {
  final List<double> rtts;
  final String? resolvedIp;
  final String method; // tcp | icmp

  const LatencySample(this.rtts, {this.resolvedIp, this.method = 'tcp'});

  static const LatencySample empty = LatencySample([]);

  List<double> get answered => rtts.where((r) => r >= 0).toList();
  bool get ok => answered.isNotEmpty;

  double get lossPercent =>
      rtts.isEmpty ? 100 : (rtts.length - answered.length) * 100 / rtts.length;

  double? get minMs =>
      answered.isEmpty ? null : answered.reduce((a, b) => a < b ? a : b);

  double? get avgMs => answered.isEmpty
      ? null
      : answered.reduce((a, b) => a + b) / answered.length;

  /// Median is what a player feels most of the time; avg is skewed by spikes.
  double? get medianMs {
    final a = answered..sort();
    if (a.isEmpty) return null;
    final m = a.length ~/ 2;
    return a.length.isOdd ? a[m] : (a[m - 1] + a[m]) / 2;
  }

  /// Mean absolute difference between consecutive answered probes (RFC 3550
  /// style, without smoothing).
  double? get jitterMs {
    final a = answered;
    if (a.length < 2) return null;
    var sum = 0.0;
    for (var i = 1; i < a.length; i++) {
      sum += (a[i] - a[i - 1]).abs();
    }
    return sum / (a.length - 1);
  }

  /// One number to rank routes by: median plus a penalty for jitter and loss
  /// (a spiky or lossy route feels worse than its median says).
  double get score {
    final med = medianMs;
    if (med == null) return double.infinity;
    return med + (jitterMs ?? 0) * 1.5 + lossPercent * 4;
  }
}

/// Real latency measurement. Never a DNS lookup timer.
class LatencyProbe {
  LatencyProbe._();

  /// Time to open a TCP connection (SYN → SYN/ACK ≈ one round trip) to
  /// [host]:[port]. The name is resolved once up front so DNS time is not
  /// counted. Works through any VPN and through firewalls that drop ICMP.
  static Future<LatencySample> tcp(
    String host,
    int port, {
    int count = 8,
    Duration timeout = const Duration(seconds: 2),
    Duration gap = const Duration(milliseconds: 180),
  }) async {
    InternetAddress? addr;
    try {
      addr = InternetAddress.tryParse(host) ??
          (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
                  .timeout(const Duration(seconds: 4)))
              .first;
    } catch (_) {
      return const LatencySample([], method: 'tcp');
    }
    final rtts = <double>[];
    for (var i = 0; i < count; i++) {
      final sw = Stopwatch()..start();
      try {
        final s = await Socket.connect(addr, port, timeout: timeout);
        sw.stop();
        s.destroy();
        rtts.add(sw.elapsedMicroseconds / 1000.0);
      } catch (_) {
        rtts.add(-1);
      }
      if (i + 1 < count) await Future.delayed(gap);
    }
    return LatencySample(rtts, resolvedIp: addr.address, method: 'tcp');
  }

  /// ICMP echo. Windows uses the runner's IcmpSendEcho; Android/Linux/macOS
  /// run the system `ping`. Returns an empty sample when ICMP is unavailable.
  static Future<LatencySample> icmp(
    String host, {
    int count = 5,
    int timeoutMs = 1000,
  }) async {
    if (Platform.isWindows) {
      final r = await WindowsNative.icmpPing(host,
          count: count, timeoutMs: timeoutMs);
      return LatencySample(r.rtts, resolvedIp: r.ip, method: 'icmp');
    }
    try {
      final args = Platform.isMacOS
          ? ['-c', '$count', '-W', '$timeoutMs', host]
          : ['-c', '$count', '-W', '${(timeoutMs / 1000).ceil()}', host];
      final res = await Process.run('ping', args)
          .timeout(Duration(milliseconds: count * (timeoutMs + 400) + 2000));
      final out = res.stdout.toString();
      final times = RegExp(r'time[=<]([\d.]+)\s*ms')
          .allMatches(out)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      final rtts = <double>[
        ...times,
        for (var i = times.length; i < count; i++) -1,
      ];
      final ip = RegExp(r'\(([\d.]+)\)').firstMatch(out)?.group(1);
      return LatencySample(rtts, resolvedIp: ip, method: 'icmp');
    } catch (_) {
      return const LatencySample([], method: 'icmp');
    }
  }

  /// ICMP first, TCP to [fallbackPort] when ICMP gets nothing back.
  static Future<LatencySample> best(String host,
      {int fallbackPort = 443, int count = 5}) async {
    final i = await icmp(host, count: count);
    if (i.ok) return i;
    return tcp(host, fallbackPort, count: count);
  }
}
