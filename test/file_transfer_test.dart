import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/models/member.dart';
import 'package:localvpn/services/file_transfer_service.dart';
import 'package:localvpn/services/p2p_crypto.dart';
import 'package:localvpn/services/p2p_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

const _vipA = '10.10.0.2';
const _vipB = '10.10.0.3';
const _vipSilent = '10.10.0.7';

class _Node {
  _Node(this.name, this.vip, this.identity)
      : p2p = P2pService(identity: identity, stunServers: const []) {
    p2p.configure(deviceId: 'device-$name', licenseKey: '');
    files.configure(p2pService: p2p, deviceId: 'device-$name', licenseKey: '');
    p2p.onFileMessage = files.handleMessage;
  }

  final String name;
  final String vip;
  final P2pIdentity identity;
  final P2pService p2p;
  final files = FileTransferService();

  NetworkMember member() => NetworkMember(
        displayName: name,
        virtualIp: vip,
        publicIp: '127.0.0.1',
        publicPort: p2p.localUdpPort,
        machineId: 'device-$name',
        p2pKey: identity.advert,
        reportsP2pKey: true,
      );
}

Future<void> _until(bool Function() done,
    {String? reason, Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: ${reason ?? ''}');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _Node a;
  late _Node b;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('lvpn_ft_');
    a = _Node('alice', _vipA, await P2pIdentity.generate());
    b = _Node('bob', _vipB, await P2pIdentity.generate());
    expect(await a.p2p.start('lan-party'), isTrue);
    expect(await b.p2p.start('lan-party'), isTrue);
    a.files.setNetwork('lan-party');
    b.files.setNetwork('lan-party');
    a.p2p.updatePeers([a.member(), b.member()]);
    b.p2p.updatePeers([b.member(), a.member()]);
    await _until(
      () =>
          a.p2p.pathOf(_vipB) == P2pPath.direct &&
          b.p2p.pathOf(_vipA) == P2pPath.direct,
      reason: 'direct path',
    );
  });

  tearDown(() async {
    await a.p2p.stop();
    await b.p2p.stop();
    await tmp.delete(recursive: true);
  });

  Future<(SharedFile, Uint8List)> share(int size) async {
    final rng = Random(size);
    final bytes =
        Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256)));
    final source = File(path.join(tmp.path, 'source.bin'));
    await source.writeAsBytes(bytes);
    final hash = sha256.convert(bytes).toString();
    a.files.debugSeedLocalFile(hash, source.path);
    final file = SharedFile(
      id: 1,
      fileHash: hash,
      fileName: r'..\..\evil:name.bin',
      fileSize: size,
      totalChunks: (size / 32768).ceil(),
      ownerDisplayName: 'alice',
    );
    final downloads = Directory(path.join(tmp.path, 'downloads'));
    b.files.debugDownloadDirectory = downloads;
    return (file, bytes);
  }

  test('a file arrives whole over P2P and is checked against its hash',
      () async {
    final (file, bytes) = await share(10 * 32768 + 777);
    final t = await b.files.debugDownloadFrom(file, [_vipA]);
    await _until(() => t.status != TransferStatus.transferring,
        reason: 'download');
    expect(t.status, TransferStatus.completed, reason: t.error);
    expect(await File(t.localPath!).readAsBytes(), bytes);
    // A hostile name can't leave the download folder.
    expect(path.dirname(t.localPath!), path.join(tmp.path, 'downloads'));
    expect(path.basename(t.localPath!), 'evil_name.bin');
    final leftovers = Directory(path.join(tmp.path, 'downloads'))
        .listSync()
        .where((e) => e.path.endsWith('.part'));
    expect(leftovers, isEmpty);
    expect(b.files.isSeeder(file.fileHash), isTrue);
  });

  test('chunks asked from a seeder that never answers come from another',
      () async {
    final (file, bytes) = await share(16 * 32768);
    final t = await b.files.debugDownloadFrom(file, [_vipA, _vipSilent]);
    await _until(() => t.status != TransferStatus.transferring,
        reason: 'download with one silent seeder',
        timeout: const Duration(seconds: 40));
    expect(t.status, TransferStatus.completed, reason: t.error);
    expect(await File(t.localPath!).readAsBytes(), bytes);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('cancelling removes the partial file', () async {
    final (file, _) = await share(64 * 32768);
    final t = await b.files.debugDownloadFrom(file, [_vipSilent]);
    b.files.cancelTransfer(file.fileHash);
    expect(t.status, TransferStatus.cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final dir = Directory(path.join(tmp.path, 'downloads'));
    expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
  });
}
