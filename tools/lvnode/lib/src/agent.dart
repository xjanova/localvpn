import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'relay_server.dart';

const String lvnodeVersion = '1.0.0';

/// Runs a command; [stdin] is written to it when given.
typedef CommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? stdin,
});

Future<ProcessResult> runCommand(
  String executable,
  List<String> arguments, {
  String? stdin,
}) async {
  if (stdin == null) return Process.run(executable, arguments);
  final process = await Process.start(executable, arguments);
  process.stdin.write(stdin);
  final results = await Future.wait([
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
    process.stdin.close(),
  ]);
  return ProcessResult(
      process.pid, await process.exitCode, results[0], results[1]);
}

/// Settings from /etc/lvnode.env (see install.sh).
class AgentConfig {
  AgentConfig({
    required this.nodeId,
    required this.secret,
    required this.api,
    required this.roles,
    this.relayPort = 51821,
    this.wgPort = 51820,
    this.wgInterface = 'wg0',
    this.wgKeyPath = '/etc/lvnode/wg.key',
    this.nic,
  });

  final int nodeId;
  final List<int> secret;
  final Uri api;
  final Set<String> roles;
  final int relayPort;
  final int wgPort;
  final String wgInterface;
  final String wgKeyPath;

  /// The interface that faces the internet; found from the default route
  /// when not set (never assume eth0).
  final String? nic;

  bool get hasRelay => roles.contains('relay');
  bool get hasExit => roles.contains('game') || roles.contains('vpn');

  static AgentConfig fromEnv(Map<String, String> env) {
    final id = int.tryParse(env['LVNODE_ID'] ?? '');
    final secret = env['LVNODE_SECRET'] ?? '';
    if (id == null || id <= 0) throw const FormatException('LVNODE_ID missing');
    if (secret.length < 16) {
      throw const FormatException('LVNODE_SECRET missing or too short');
    }
    final roles = (env['LVNODE_ROLES'] ?? 'relay')
        .split(',')
        .map((r) => r.trim().toLowerCase())
        .where((r) => const {'relay', 'game', 'vpn'}.contains(r))
        .toSet();
    if (roles.isEmpty) throw const FormatException('LVNODE_ROLES is empty');
    final iface = env['LVNODE_WG_IFACE'] ?? 'wg0';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,15}$').hasMatch(iface)) {
      throw const FormatException('LVNODE_WG_IFACE is not an interface name');
    }
    return AgentConfig(
      nodeId: id,
      secret: utf8.encode(secret),
      api: Uri.parse(
          env['LVNODE_API'] ?? 'https://xman4289.com/api/v1/localvpn'),
      roles: roles,
      relayPort: int.tryParse(env['LVNODE_RELAY_PORT'] ?? '') ?? 51821,
      wgPort: int.tryParse(env['LVNODE_WG_PORT'] ?? '') ?? 51820,
      wgInterface: iface,
      wgKeyPath: env['LVNODE_WG_KEY'] ?? '/etc/lvnode/wg.key',
      nic: env['LVNODE_NIC'],
    );
  }
}

/// Answer of one sync request.
class SyncResponse {
  SyncResponse(this.status, this.body);
  final int status;
  final String body;
}

typedef SyncSender = Future<SyncResponse> Function(
  Uri url,
  Map<String, String> headers,
  String body,
);

/// The node: runs the relay, keeps WireGuard peers and the firewall in line
/// with what the backend says, and reports usage every sync.
class NodeAgent {
  NodeAgent(
    this.config, {
    CommandRunner? run,
    SyncSender? send,
    void Function(String line)? log,
    this.readFile = _readFile,
  })  : _run = run ?? runCommand,
        _sendSync = send ?? _httpPost,
        _log = log ?? ((line) => stdout.writeln(line));

  final AgentConfig config;
  final CommandRunner _run;
  final SyncSender _sendSync;
  final void Function(String) _log;
  final Future<String?> Function(String path) readFile;

  /// Private and reserved ranges an exit never forwards to (the provider's
  /// internal network, cloud metadata, multicast).
  static const List<String> blockedRanges = [
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '224.0.0.0/4',
  ];

  RelayServer? relay;
  Timer? _timer;
  Duration interval = const Duration(seconds: 10);
  bool _stopped = false;
  String? nic;
  String? wgPublicKey;

  // Counters not yet accepted by the backend.
  int _nicRx = -1, _nicTx = -1;
  int _pendingNicRx = 0, _pendingNicTx = 0;
  int _relayRx = 0, _relayTx = 0;
  int _pendingRelayRx = 0, _pendingRelayTx = 0;
  final Map<String, int> _pendingRelay = {};
  final Map<String, (int, int)> _wgCounters = {};
  final Map<String, (int, int)> _pendingExit = {};
  int _exitPeers = 0;
  int _lastTime = 0;
  int _syncs = 0;

  String _ifaceState = '';
  String _natState = '';
  String _forwardState = '';

  Future<void> start() async {
    _log('lvnode $lvnodeVersion node=${config.nodeId} '
        'roles=${config.roles.join(',')}');
    nic = config.nic ?? await defaultInterface();
    _log('internet interface: ${nic ?? 'unknown'}');
    if (config.hasRelay) {
      final r = RelayServer(nodeId: config.nodeId, secret: config.secret);
      await r.bind(port: config.relayPort);
      relay = r;
      _log('relay listening on udp/${config.relayPort}');
    }
    if (config.hasExit) {
      wgPublicKey = await _publicKeyFromFile();
    }
    await _readNic(); // baseline
    unawaited(_loop());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    relay?.close();
  }

  Future<void> _loop() async {
    if (_stopped) return;
    try {
      await syncOnce();
    } catch (e) {
      _log('sync failed: $e');
    }
    if (!_stopped) _timer = Timer(interval, _loop);
  }

  /// One report → one set of instructions.
  Future<void> syncOnce() async {
    // Firewall rules may have been flushed (ufw reload, a reboot of
    // iptables-persistent): check ours again every ~5 minutes.
    if (++_syncs % 30 == 0) _natState = '';
    await _collect();
    final body = jsonEncode(buildReport());
    var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (time <= _lastTime) time = _lastTime + 1;
    _lastTime = time;
    final signature =
        Hmac(sha256, config.secret).convert(utf8.encode('$time.$body')).toString();
    final response = await _sendSync(
      config.api.replace(path: '${config.api.path}/node/sync'),
      {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Node-Id': '${config.nodeId}',
        'X-Node-Time': '$time',
        'X-Node-Signature': signature,
      },
      body,
    );
    if (response.status != 200) {
      _log('sync refused: HTTP ${response.status} '
          '${response.body.substring(0, min(200, response.body.length))}');
      return; // counters stay pending for the next try
    }
    _clearPending();
    final json = jsonDecode(response.body);
    if (json is Map<String, dynamic>) await apply(json);
  }

  Map<String, dynamic> buildReport() => {
        'agent': 'lvnode/$lvnodeVersion',
        'roles': config.roles.toList()..sort(),
        if (wgPublicKey != null) 'wg_public_key': wgPublicKey,
        'wg_port': config.wgPort,
        'relay_port': config.relayPort,
        'nic': {'rx': _pendingNicRx, 'tx': _pendingNicTx},
        'relay': {
          'clients': relay?.clientCount ?? 0,
          'rx': _pendingRelayRx,
          'tx': _pendingRelayTx,
          'usage': [
            for (final e in _pendingRelay.entries.take(20000))
              {
                'net': int.parse(e.key.substring(0, e.key.indexOf('|'))),
                'vip': e.key.substring(e.key.indexOf('|') + 1),
                'bytes': e.value,
              },
          ],
        },
        'exit': {
          'peers': _exitPeers,
          'usage': [
            for (final e in _pendingExit.entries.take(20000))
              {'pub': e.key, 'rx': e.value.$1, 'tx': e.value.$2},
          ],
        },
        'load1': _load1,
      };

  double _load1 = 0;

  Future<void> _collect() async {
    await _readNic();
    final r = relay;
    if (r != null) {
      _pendingRelayRx += r.stats.rx - _relayRx;
      _pendingRelayTx += r.stats.tx - _relayTx;
      _relayRx = r.stats.rx;
      _relayTx = r.stats.tx;
      for (final u in r.takeUsage()) {
        final key = '${u.network}|${u.vip}';
        _pendingRelay[key] = (_pendingRelay[key] ?? 0) + u.bytes;
      }
    }
    if (config.hasExit) await _collectExit();
    final load = await readFile('/proc/loadavg');
    _load1 = double.tryParse(load?.split(' ').first ?? '') ?? 0;
  }

  void _clearPending() {
    _pendingNicRx = 0;
    _pendingNicTx = 0;
    _pendingRelayRx = 0;
    _pendingRelayTx = 0;
    _pendingRelay.clear();
    _pendingExit.clear();
  }

  Future<void> _readNic() async {
    final n = nic;
    if (n == null) return;
    final rx = int.tryParse(
        (await readFile('/sys/class/net/$n/statistics/rx_bytes'))?.trim() ?? '');
    final tx = int.tryParse(
        (await readFile('/sys/class/net/$n/statistics/tx_bytes'))?.trim() ?? '');
    if (rx == null || tx == null) return;
    // A counter that went down means the interface was reset.
    if (_nicRx >= 0) _pendingNicRx += rx >= _nicRx ? rx - _nicRx : rx;
    if (_nicTx >= 0) _pendingNicTx += tx >= _nicTx ? tx - _nicTx : tx;
    _nicRx = rx;
    _nicTx = tx;
  }

  /// The interface of the default route, from /proc/net/route.
  Future<String?> defaultInterface() async {
    final table = await readFile('/proc/net/route');
    if (table == null) return null;
    for (final line in const LineSplitter().convert(table).skip(1)) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length > 2 && cols[1] == '00000000') return cols[0];
    }
    return null;
  }

  // ── Instructions from the backend ─────────────────────────────────────

  Future<void> apply(Map<String, dynamic> json) async {
    final seconds = _asInt(json['sync_interval_s']);
    if (seconds != null) interval = Duration(seconds: seconds.clamp(5, 120));
    final status = switch (json['status']) {
      'draining' => RelayStatus.draining,
      'disabled' => RelayStatus.disabled,
      _ => RelayStatus.active,
    };
    final budget = json['budget'];
    final acceptNew = budget is! Map || budget['accept_new'] != false;

    final r = relay;
    if (r != null) {
      final relayConfig = json['relay'];
      final enabled = relayConfig is! Map || relayConfig['enabled'] != false;
      r.status = enabled ? status : RelayStatus.disabled;
      r.acceptNew = acceptNew;
      final maxClients =
          relayConfig is Map ? _asInt(relayConfig['max_clients']) : null;
      if (maxClients != null && maxClients > 0) r.maxClients = maxClients;
    }
    if (config.hasExit) {
      final exit = json['exit'];
      await applyExit(exit is Map ? Map<String, dynamic>.from(exit) : null,
          status);
    }
  }

  Future<void> applyExit(Map<String, dynamic>? exit, RelayStatus status) async {
    final enabled = exit?['enabled'] == true && status != RelayStatus.disabled;
    final address = exit?['address'];
    if (address is! String || parseCidr(address) == null) {
      if (_ifaceState.isNotEmpty) await syncPeers(const {});
      return;
    }
    final port = _asInt(exit?['listen_port']) ?? config.wgPort;
    await _ensureInterface(address, port);
    await _ensureNat(address);
    final mode = exit?['mode'] == 'vpn' ? 'vpn' : 'game';
    final cidrs = <String>[
      for (final c in exit?['allow_cidrs'] as List? ?? const [])
        if (c is String && parseCidr(c) != null) c,
    ];
    await applyForwardPolicy(mode, cidrs);

    final desired = <String, String>{};
    if (enabled) {
      final subnet = parseCidr(address)!;
      for (final p in exit?['peers'] as List? ?? const []) {
        if (p is! Map) continue;
        final pub = p['pub'];
        final ip = p['ip'];
        if (pub is! String || !_isWgKey(pub) || ip is! String) continue;
        final ipValue = _ipv4(ip);
        if (ipValue == null || !subnet.contains(ipValue)) continue;
        desired[pub] = ip;
      }
    }
    await syncPeers(desired);
  }

  Future<void> _ensureInterface(String address, int port) async {
    final state = '$address|$port';
    if (state == _ifaceState) return;
    final iface = config.wgInterface;
    if ((await _run('ip', ['link', 'show', iface])).exitCode != 0) {
      await _must('ip', ['link', 'add', iface, 'type', 'wireguard']);
    }
    await _must('wg', [
      'set', iface, 'listen-port', '$port', //
      'private-key', config.wgKeyPath,
    ]);
    await _must('ip', ['address', 'flush', 'dev', iface]);
    await _must('ip', ['address', 'add', address, 'dev', iface]);
    await _must('ip', ['link', 'set', iface, 'mtu', '1420', 'up']);
    final pub = await _run('wg', ['show', iface, 'public-key']);
    if (pub.exitCode == 0) wgPublicKey = '${pub.stdout}'.trim();
    _ifaceState = state;
    _log('wireguard $iface up: $address port $port');
  }

  Future<void> _ensureNat(String address) async {
    final subnet = parseCidr(address)!.network;
    final out = nic;
    final state = '$subnet|$out';
    if (out == null || state == _natState) return;
    final iface = config.wgInterface;
    await readFile('/proc/sys/net/ipv4/ip_forward').then((v) async {
      if (v?.trim() != '1') {
        await _run('sysctl', ['-w', 'net.ipv4.ip_forward=1']);
      }
    });
    await _ensureRule(['-t', 'nat'], 'POSTROUTING',
        ['-s', subnet, '-o', out, '-j', 'MASQUERADE']);
    for (final chain in ['LVNODE_FWD', 'LVNODE_IN']) {
      await _run('iptables', ['-N', chain]); // fails harmlessly if it exists
    }
    await _ensureRule([], 'FORWARD', ['-i', iface, '-j', 'LVNODE_FWD'],
        insert: true);
    await _ensureRule(
        [],
        'FORWARD',
        ['-o', iface, '-m', 'conntrack', '--ctstate', 'RELATED,ESTABLISHED', '-j', 'ACCEPT'],
        insert: true);
    await _ensureRule([], 'INPUT', ['-i', iface, '-j', 'LVNODE_IN'],
        insert: true);
    // Clients may ping the gateway (latency tests); nothing else on the
    // node (ssh, the panel) is reachable through the tunnel.
    await _must('iptables', ['-F', 'LVNODE_IN']);
    await _must('iptables', ['-A', 'LVNODE_IN', '-p', 'icmp', '-j', 'ACCEPT']);
    await _must('iptables', ['-A', 'LVNODE_IN', '-j', 'DROP']);
    _natState = state;
  }

  /// Game mode forwards only to the admin's game CIDRs; vpn mode to the
  /// whole internet. Private ranges and SMTP are blocked in both.
  Future<void> applyForwardPolicy(String mode, List<String> cidrs) async {
    final sorted = [...cidrs]..sort();
    final state = '$mode|${sorted.join(',')}';
    if (state == _forwardState) return;
    if (mode == 'game') {
      await _must('ipset', ['create', 'lv_allow', 'hash:net', '-exist']);
      await _must('ipset', ['create', 'lv_allow_new', 'hash:net', '-exist']);
      await _must('ipset', ['flush', 'lv_allow_new']);
      if (sorted.isNotEmpty) {
        await _must('ipset', ['restore', '-exist'],
            stdin: '${sorted.map((c) => 'add lv_allow_new $c').join('\n')}\n');
      }
      await _must('ipset', ['swap', 'lv_allow_new', 'lv_allow']);
      await _run('ipset', ['destroy', 'lv_allow_new']);
    }
    await _must('iptables', ['-F', 'LVNODE_FWD']);
    for (final range in blockedRanges) {
      await _must('iptables', ['-A', 'LVNODE_FWD', '-d', range, '-j', 'DROP']);
    }
    await _must('iptables',
        ['-A', 'LVNODE_FWD', '-p', 'tcp', '--dport', '25', '-j', 'DROP']);
    if (mode == 'game') {
      await _must('iptables', [
        '-A', 'LVNODE_FWD', '-m', 'set', '!', '--match-set', 'lv_allow', //
        'dst', '-j', 'DROP',
      ]);
    }
    await _must('iptables', ['-A', 'LVNODE_FWD', '-j', 'ACCEPT']);
    _forwardState = state;
    _log('exit policy: $mode, ${sorted.length} allowed ranges');
  }

  /// Makes the interface's peers exactly [desired] (public key → IP).
  Future<void> syncPeers(Map<String, String> desired) async {
    final iface = config.wgInterface;
    final dump = await _run('wg', ['show', iface, 'dump']);
    if (dump.exitCode != 0) return;
    final current = <String, String>{};
    for (final line in const LineSplitter().convert('${dump.stdout}').skip(1)) {
      final cols = line.split('\t');
      if (cols.length >= 4) current[cols[0]] = cols[3];
    }
    var changes = 0;
    for (final e in desired.entries) {
      if (current[e.key] == '${e.value}/32') continue;
      await _must('wg',
          ['set', iface, 'peer', e.key, 'allowed-ips', '${e.value}/32']);
      changes++;
    }
    for (final pub in current.keys) {
      if (desired.containsKey(pub)) continue;
      await _must('wg', ['set', iface, 'peer', pub, 'remove']);
      _wgCounters.remove(pub);
      changes++;
    }
    _exitPeers = desired.length;
    if (changes > 0) _log('wireguard peers: ${desired.length} ($changes changed)');
  }

  Future<void> _collectExit() async {
    final dump = await _run('wg', ['show', config.wgInterface, 'dump']);
    if (dump.exitCode != 0) return;
    for (final line in const LineSplitter().convert('${dump.stdout}').skip(1)) {
      final cols = line.split('\t');
      if (cols.length < 7) continue;
      final rx = int.tryParse(cols[5]) ?? 0;
      final tx = int.tryParse(cols[6]) ?? 0;
      final last = _wgCounters[cols[0]];
      final dRx = last == null ? rx : (rx >= last.$1 ? rx - last.$1 : rx);
      final dTx = last == null ? tx : (tx >= last.$2 ? tx - last.$2 : tx);
      _wgCounters[cols[0]] = (rx, tx);
      if (dRx == 0 && dTx == 0) continue;
      final pending = _pendingExit[cols[0]] ?? (0, 0);
      _pendingExit[cols[0]] = (pending.$1 + dRx, pending.$2 + dTx);
    }
  }

  Future<String?> _publicKeyFromFile() async {
    final key = await readFile(config.wgKeyPath);
    if (key == null) return null;
    final result = await _run('wg', ['pubkey'], stdin: key.trim());
    return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
  }

  Future<void> _ensureRule(List<String> table, String chain, List<String> rule,
      {bool insert = false}) async {
    final check = await _run('iptables', [...table, '-C', chain, ...rule]);
    if (check.exitCode == 0) return;
    await _must('iptables',
        [...table, if (insert) ...['-I', chain, '1'] else ...['-A', chain], ...rule]);
  }

  Future<void> _must(String exe, List<String> args, {String? stdin}) async {
    final result = await _run(exe, args, stdin: stdin);
    if (result.exitCode != 0) {
      _log('command failed: $exe ${args.join(' ')}: ${'${result.stderr}'.trim()}');
    }
  }

  static bool _isWgKey(String s) =>
      s.length == 44 && RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(s);

  static int? _asInt(Object? v) => switch (v) {
        final int i => i,
        final num n => n.toInt(),
        final String s => int.tryParse(s),
        _ => null,
      };

  static Future<String?> _readFile(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<SyncResponse> _httpPost(
      Uri url, Map<String, String> headers, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.add(utf8.encode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return SyncResponse(response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }
}

/// An IPv4 CIDR.
class Cidr {
  Cidr(this.base, this.prefix);
  final int base;
  final int prefix;

  int get mask => prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  bool contains(int ip) => (ip & mask) == (base & mask);
  String get network {
    final n = base & mask;
    return '${n >> 24 & 255}.${n >> 16 & 255}.${n >> 8 & 255}.${n & 255}/$prefix';
  }
}

Cidr? parseCidr(String s) {
  final slash = s.indexOf('/');
  if (slash <= 0) return null;
  final ip = _ipv4(s.substring(0, slash));
  final prefix = int.tryParse(s.substring(slash + 1));
  if (ip == null || prefix == null || prefix < 0 || prefix > 32) return null;
  return Cidr(ip, prefix);
}

int? _ipv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  var v = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255 || p.length > 3) return null;
    v = (v << 8) | n;
  }
  return v;
}
