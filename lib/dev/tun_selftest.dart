import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../platform/windows_native.dart';

/// `LocalVPN.exe --selftest-tun <result.json>` (run as administrator).
///
/// Proves the Windows packet path end to end without a second machine:
/// brings the Wintun adapter up as 10.99.0.2/24, pings 10.99.0.3 through
/// it, answers each echo request by injecting a hand-built echo reply, and
/// checks that a subnet broadcast is captured too. Writes a JSON report and
/// exits; the adapter is removed again.
Future<void> runTunSelfTest(String outPath) async {
  const ch = MethodChannel('com.xjanova.localvpn/vpn');
  final report = <String, Object?>{};
  var captured = 0;
  var echoRequests = 0;
  var broadcastSeen = false;
  var injected = 0;

  ch.setMethodCallHandler((call) async {
    if (call.method != 'onTunPackets') return;
    for (final p in (call.arguments as List).cast<Uint8List>()) {
      captured++;
      if (p.length >= 20 && p[16] == 10 && p[17] == 99 && p[19] == 255) {
        broadcastSeen = true;
      }
      final reply = _echoReplyFor(p);
      if (reply != null) {
        echoRequests++;
        final ok = await ch.invokeMethod<bool>('injectPacket', {'data': reply});
        if (ok == true) injected++;
      }
    }
  });

  try {
    report['elevated'] = await WindowsNative.isElevated();
    final started = await ch.invokeMethod<bool>('startVpn', {
      'virtualIp': '10.99.0.2',
      'subnet': '10.99.0.0/24',
      'peers': <Object>[],
      'useP2p': false,
    });
    report['started'] = started;
    // Duplicate-address detection keeps a new IP "tentative" briefly.
    await Future.delayed(const Duration(seconds: 3));

    final ping = await WindowsNative.icmpPing('10.99.0.3',
        count: 4, timeoutMs: 1500);
    report['pingRtts'] = ping.rtts;
    report['pingAnswered'] = ping.answered.length;

    final sock = await RawDatagramSocket.bind(InternetAddress('10.99.0.2'), 0);
    sock.broadcastEnabled = true;
    sock.send(utf8.encode('LocalVPN LAN discovery'),
        InternetAddress('10.99.0.255'), 47777);
    await Future.delayed(const Duration(milliseconds: 800));
    sock.close();

    report['stats'] = await ch.invokeMethod('getStats');
  } on PlatformException catch (e) {
    report['error'] = '${e.code}: ${e.message}';
  } catch (e) {
    report['error'] = e.toString();
  } finally {
    try {
      await ch.invokeMethod('stopVpn');
    } catch (_) {}
  }

  report['captured'] = captured;
  report['echoRequests'] = echoRequests;
  report['injected'] = injected;
  report['broadcastSeen'] = broadcastSeen;
  report['pass'] = report['started'] == true &&
      (report['pingAnswered'] as int? ?? 0) >= 3 &&
      broadcastSeen;
  await File(outPath)
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  exit(0);
}

/// ICMP echo request to 10.99.0.3 → matching echo reply (swap addresses,
/// type 0, fresh checksums). Null for anything else.
Uint8List? _echoReplyFor(Uint8List p) {
  if (p.length < 28 || (p[0] >> 4) != 4) return null;
  final ihl = (p[0] & 0x0F) * 4;
  if (p[9] != 1 || p.length < ihl + 8) return null; // ICMP
  if (p[ihl] != 8) return null; // echo request
  if (!(p[16] == 10 && p[17] == 99 && p[18] == 0 && p[19] == 3)) return null;

  final r = Uint8List.fromList(p);
  // Swap source and destination.
  for (var i = 0; i < 4; i++) {
    final t = r[12 + i];
    r[12 + i] = r[16 + i];
    r[16 + i] = t;
  }
  r[8] = 64; // TTL
  r[10] = 0;
  r[11] = 0;
  final ipSum = _checksum(r, 0, ihl);
  r[10] = ipSum >> 8;
  r[11] = ipSum & 0xFF;

  r[ihl] = 0; // echo reply
  r[ihl + 2] = 0;
  r[ihl + 3] = 0;
  final icmpSum = _checksum(r, ihl, r.length - ihl);
  r[ihl + 2] = icmpSum >> 8;
  r[ihl + 3] = icmpSum & 0xFF;
  return r;
}

int _checksum(Uint8List b, int start, int len) {
  var sum = 0;
  for (var i = 0; i + 1 < len; i += 2) {
    sum += (b[start + i] << 8) | b[start + i + 1];
  }
  if (len.isOdd) sum += b[start + len - 1] << 8;
  while (sum >> 16 != 0) {
    sum = (sum & 0xFFFF) + (sum >> 16);
  }
  return (~sum) & 0xFFFF;
}
