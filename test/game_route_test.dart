import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/services/game_boost_service.dart';
import 'package:localvpn/services/vpn_proxy_service.dart';

void main() {
  test('game profiles keep only valid IPv4 ranges and match their region',
      () {
    final p = GameProfile.fromJson({
      'slug': 'valorant-sea',
      'name': 'Valorant (SEA)',
      'region': 'SG',
      'cidrs': ['43.229.64.0/18', 'bad', '10.0.0.0/33', ' 103.10.124.0/23 '],
      'probe_host': '43.229.65.1:443',
    })!;
    expect(p.cidrs, ['43.229.64.0/18', '103.10.124.0/23']);
    final sg = GameBoostService.regions.firstWhere((r) => r.id == 'sg');
    final jp = GameBoostService.regions.firstWhere((r) => r.id == 'jp');
    expect(p.inRegion(sg), isTrue);
    expect(p.inRegion(jp), isFalse);
    expect(GameProfile.fromJson({'slug': 'x', 'name': 'x', 'cidrs': ['bad']}),
        isNull);
  });

  test('a game route tunnels only the game ranges and keeps local DNS', () {
    final parts = {
      'address': '10.66.0.5/32',
      'dns': '1.1.1.1',
      'server_pub_key': 'PUB=',
      'endpoint': '203.0.113.10:51820',
      'allowed_ips': '0.0.0.0/0',
    };
    final svc = VpnProxyService();
    final game = svc.debugWgConfig(parts,
        routing: WgRouting.games,
        routes: ['43.229.64.0/18', '52.220.1.2/32']);
    expect(game, contains('AllowedIPs = 43.229.64.0/18, 52.220.1.2/32\n'));
    expect(game, isNot(contains('DNS =')));
    expect(game, isNot(contains('0.0.0.0/0')));

    final full = svc.debugWgConfig(parts, routing: WgRouting.server);
    expect(full, contains('AllowedIPs = 0.0.0.0/0'));
    expect(full, contains('DNS = 1.1.1.1'));
  });
}
