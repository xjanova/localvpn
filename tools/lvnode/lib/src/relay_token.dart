import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A relay ticket issued by the backend with the heartbeat:
/// `v1.<node>.<network>.<vip>.<exp>.<kbps>.<daily_mb>.<sig>` where
/// `sig = hex(HMAC-SHA256(node secret, everything before ".<sig>"))`.
///
/// Must stay byte-compatible with the backend (docs/RELAY_FLEET.md).
class RelayToken {
  const RelayToken({
    required this.node,
    required this.network,
    required this.vip,
    required this.expires,
    required this.kbps,
    required this.dailyMb,
  });

  final int node;
  final int network;
  final String vip;

  /// Unix seconds.
  final int expires;

  /// Rate cap in kilobits per second; 0 = none.
  final int kbps;

  /// Daily cap in MiB; 0 = none.
  final int dailyMb;

  /// The ticket, if [token] is well formed and signed with [secret].
  static RelayToken? verify(String token, List<int> secret) {
    if (token.length > 400) return null;
    final parts = token.split('.');
    if (parts.length != 11 || parts[0] != 'v1') return null;
    final sig = parts[10].toLowerCase();
    if (sig.length != 64) return null;
    final signed = token.substring(0, token.length - 65);
    final expected =
        Hmac(sha256, secret).convert(utf8.encode(signed)).toString();
    if (!_equal(expected, sig)) return null;

    final numbers = [parts[1], parts[2], parts[7], parts[8], parts[9]]
        .map(_number)
        .toList();
    if (numbers.contains(null)) return null;
    final octets = parts.sublist(3, 7).map(_number).toList();
    if (octets.any((o) => o == null || o > 255)) return null;
    return RelayToken(
      node: numbers[0]!,
      network: numbers[1]!,
      vip: octets.join('.'),
      expires: numbers[2]!,
      kbps: numbers[3]!,
      dailyMb: numbers[4]!,
    );
  }

  /// Signs a ticket the way the backend does (tests and tooling).
  static String sign({
    required int node,
    required int network,
    required String vip,
    required int expires,
    int kbps = 0,
    int dailyMb = 0,
    required List<int> secret,
  }) {
    final body = 'v1.$node.$network.$vip.$expires.$kbps.$dailyMb';
    final sig = Hmac(sha256, secret).convert(utf8.encode(body)).toString();
    return '$body.$sig';
  }

  static int? _number(String s) {
    if (s.isEmpty || s.length > 12) return null;
    final v = int.tryParse(s);
    return v == null || v < 0 ? null : v;
  }

  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
