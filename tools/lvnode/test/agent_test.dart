import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:lvnode/lvnode.dart';
import 'package:test/test.dart';

const _pubA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _pubB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
const _pubOld = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=';

class _Fake {
  final commands = <String>[];
  final files = <String, String>{
    '/proc/net/route': 'Iface\tDestination\tGateway\n'
        'ens33\t00000000\t0102A8C0\n'
        'ens33\t0002A8C0\t00000000\n',
    '/sys/class/net/ens33/statistics/rx_bytes': '1000\n',
    '/sys/class/net/ens33/statistics/tx_bytes': '5000\n',
    '/proc/loadavg': '0.25 0.20 0.10 1/100 1234\n',
    '/proc/sys/net/ipv4/ip_forward': '1\n',
    '/etc/lvnode/wg.key': 'private\n',
  };
  String wgDump = 'priv\tpub\t51820\toff\n'
      '$_pubOld\t(none)\t1.2.3.4:5555\t10.66.0.9/32\t0\t100\t200\toff\n';
  final sent = <(Uri, Map<String, String>, String)>[];
  String answer = '{"ok":true}';
  int status = 200;

  Future<ProcessResult> run(String exe, List<String> args,
      {String? stdin}) async {
    final line = '$exe ${args.join(' ')}';
    commands.add(line);
    if (line == 'wg show wg0 dump') return ProcessResult(0, 0, wgDump, '');
    if (line == 'wg show wg0 public-key') {
      return ProcessResult(0, 0, 'NODEPUB=\n', '');
    }
    if (line == 'wg pubkey') return ProcessResult(0, 0, 'NODEPUB=\n', '');
    // "iptables -C" answers "no such rule" so the agent adds it.
    if (args.contains('-C')) return ProcessResult(0, 1, '', 'no rule');
    if (line == 'ip link show wg0') return ProcessResult(0, 1, '', 'none');
    return ProcessResult(0, 0, '', '');
  }

  Future<SyncResponse> send(
      Uri url, Map<String, String> headers, String body) async {
    sent.add((url, headers, body));
    return SyncResponse(status, answer);
  }
}

NodeAgent _agent(_Fake fake, {String roles = 'relay,game'}) => NodeAgent(
      AgentConfig.fromEnv({
        'LVNODE_ID': '3',
        'LVNODE_SECRET': 'sixteen-chars-secret',
        'LVNODE_ROLES': roles,
        'LVNODE_API': 'https://example.test/api/v1/localvpn',
      }),
      run: fake.run,
      send: fake.send,
      log: (_) {},
      readFile: (path) async => fake.files[path],
    );

void main() {
  test('config refuses a missing id, short secret or unknown roles', () {
    expect(() => AgentConfig.fromEnv({}), throwsFormatException);
    expect(
        () => AgentConfig.fromEnv({'LVNODE_ID': '1', 'LVNODE_SECRET': 'short'}),
        throwsFormatException);
    expect(
        () => AgentConfig.fromEnv({
              'LVNODE_ID': '1',
              'LVNODE_SECRET': 'sixteen-chars-secret',
              'LVNODE_ROLES': 'mining',
            }),
        throwsFormatException);
  });

  test('finds the internet interface from the default route', () async {
    final fake = _Fake();
    expect(await _agent(fake).defaultInterface(), 'ens33');
  });

  test('sync is signed over time and body, and counters wait for an OK',
      () async {
    final fake = _Fake();
    final agent = _agent(fake, roles: 'relay');
    agent.nic = 'ens33';
    await agent.syncOnce(); // baseline read happens on the first collect
    fake.files['/sys/class/net/ens33/statistics/tx_bytes'] = '9000\n';
    fake.status = 500;
    await agent.syncOnce();
    fake.status = 200;
    await agent.syncOnce();

    final (url, headers, body) = fake.sent.last;
    expect(url.toString(), 'https://example.test/api/v1/localvpn/node/sync');
    expect(headers['X-Node-Id'], '3');
    final expected = Hmac(sha256, utf8.encode('sixteen-chars-secret'))
        .convert(utf8.encode('${headers['X-Node-Time']}.$body'))
        .toString();
    expect(headers['X-Node-Signature'], expected);
    // The 4000 bytes sent during the refused sync are still reported.
    expect((jsonDecode(body) as Map)['nic'], {'rx': 0, 'tx': 4000});
    final times = [for (final s in fake.sent) int.parse(s.$2['X-Node-Time']!)];
    expect(times, orderedEquals([...times]..sort()));
    expect(times.toSet().length, times.length, reason: 'never repeats');
  });

  test('a clock far off is corrected from the backend time', () async {
    final fake = _Fake();
    final agent = _agent(fake, roles: 'relay');
    final serverTime = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    fake.status = 401;
    fake.answer = '{"ok":false,"error":"stale-time","server_time":$serverTime}';
    await agent.syncOnce();
    fake.status = 200;
    fake.answer = '{"ok":true}';
    await agent.syncOnce();
    final sent = int.parse(fake.sent.last.$2['X-Node-Time']!);
    expect((sent - serverTime).abs(), lessThan(5));
  });

  test('a report refused as too large drops the per-member detail', () async {
    final fake = _Fake();
    final agent = _agent(fake, roles: 'relay');
    agent.relay = RelayServer(nodeId: 3, secret: utf8.encode('x' * 16));
    fake.status = 413;
    await agent.syncOnce();
    fake.status = 200;
    await agent.syncOnce();
    final body = jsonDecode(fake.sent.last.$3) as Map;
    expect((body['relay'] as Map)['usage'], isEmpty);
  });

  test('a game exit: interface, NAT on the real interface, game-only forward',
      () async {
    final fake = _Fake();
    final agent = _agent(fake);
    agent.nic = 'ens33';
    await agent.apply({
      'status': 'active',
      'exit': {
        'enabled': true,
        'mode': 'game',
        'address': '10.66.0.1/24',
        'listen_port': 51820,
        'allow_cidrs': ['43.229.64.0/18', 'not-a-cidr', '103.10.124.0/23'],
        'peers': [
          {'pub': _pubA, 'ip': '10.66.0.5'},
          {'pub': _pubB, 'ip': '10.99.0.5'}, // outside the subnet
          {'pub': 'short', 'ip': '10.66.0.6'},
        ],
      },
    });
    final c = fake.commands;
    expect(c, contains('ip link add wg0 type wireguard'));
    expect(c, contains('ip address add 10.66.0.1/24 dev wg0'));
    expect(c, contains('iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT'));
    expect(c,
        contains('iptables -t nat -A POSTROUTING -s 10.66.0.0/24 -o ens33 -j MASQUERADE'));
    expect(c, contains('iptables -A LVNODE_FWD -d 169.254.0.0/16 -j DROP'));
    expect(c, contains('iptables -A LVNODE_FWD -m set ! --match-set lv_allow dst -j DROP'));
    expect(c, contains('iptables -A LVNODE_IN -j DROP'));
    expect(c, contains('wg set wg0 peer $_pubA allowed-ips 10.66.0.5/32'));
    expect(c, contains('wg set wg0 peer $_pubOld remove'));
    expect(c.where((l) => l.contains(_pubB)), isEmpty);
    expect(c.where((l) => l.contains('not-a-cidr')), isEmpty);
    expect(agent.wgPublicKey, 'NODEPUB=');
  });

  test('vpn mode forwards everything but private ranges and SMTP', () async {
    final fake = _Fake();
    final agent = _agent(fake, roles: 'vpn');
    agent.nic = 'ens33';
    await agent.applyForwardPolicy('vpn', const []);
    expect(fake.commands.where((l) => l.contains('match-set')), isEmpty);
    expect(fake.commands,
        contains('iptables -A LVNODE_FWD -p tcp --dport 25 -j DROP'));
    expect(fake.commands.last, 'iptables -A LVNODE_FWD -j ACCEPT');
  });

  test('a disabled node drops every WireGuard peer and stops relaying',
      () async {
    final fake = _Fake();
    final agent = _agent(fake);
    agent.nic = 'ens33';
    agent.relay = RelayServer(nodeId: 3, secret: utf8.encode('x' * 16));
    await agent.apply({
      'status': 'disabled',
      'exit': {'enabled': true, 'address': '10.66.0.1/24', 'peers': [
        {'pub': _pubA, 'ip': '10.66.0.5'},
      ]},
    });
    expect(agent.relay!.status, RelayStatus.disabled);
    expect(fake.commands, contains('wg set wg0 peer $_pubOld remove'));
    expect(fake.commands.where((l) => l.contains(_pubA)), isEmpty);
  });

  test('relay tokens: signature, fields and tampering', () {
    final secret = utf8.encode('node-secret-0123456789');
    final token = RelayToken.sign(
        node: 3, network: 12, vip: '10.10.0.2', expires: 1700000000,
        kbps: 1500, dailyMb: 300, secret: secret);
    final t = RelayToken.verify(token, secret)!;
    expect([t.node, t.network, t.vip, t.expires, t.kbps, t.dailyMb],
        [3, 12, '10.10.0.2', 1700000000, 1500, 300]);
    expect(RelayToken.verify(token.replaceFirst('.1500.', '.9999.'), secret),
        isNull);
    expect(RelayToken.verify(token, utf8.encode('other')), isNull);
    expect(RelayToken.verify('v1.3.12.10.10.0.300.1.0.0.$token', secret),
        isNull);
  });
}
