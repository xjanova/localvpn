import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/services/net/cidr.dart';
import 'package:localvpn/services/net/latency_probe.dart';

int _size(Cidr c) => 1 << (32 - c.prefix);

void main() {
  group('Cidr.allExcept', () {
    test('internet-only routes never touch local ranges and cover the rest',
        () {
      final routes = Cidr.allExcept(Cidr.localRanges);
      for (final r in routes) {
        for (final local in Cidr.localRanges) {
          expect(r.overlaps(local), isFalse, reason: '$r overlaps $local');
        }
        expect(r.prefix, greaterThan(0), reason: 'a /0 turns on the kill switch');
      }
      final covered = routes.fold<int>(0, (a, c) => a + _size(c));
      final excluded = Cidr.localRanges.fold<int>(0, (a, c) => a + _size(c));
      expect(covered + excluded, 1 << 32);
    });

    test('routes do not overlap each other', () {
      final routes = Cidr.allExcept(Cidr.localRanges);
      for (var i = 0; i < routes.length; i++) {
        for (var j = i + 1; j < routes.length; j++) {
          expect(routes[i].overlaps(routes[j]), isFalse);
        }
      }
    });

    test('nothing excluded still avoids a /0', () {
      final routes = Cidr.allExcept(const []);
      expect(routes.map((c) => c.toString()), ['0.0.0.0/1', '128.0.0.0/1']);
    });

    test('a bypassed endpoint is left out', () {
      final text = Cidr.internetOnlyAllowedIps(bypass: ['203.0.113.7/32']);
      final routes = text.split(', ').map((e) => Cidr.parse(e)!).toList();
      final endpoint = Cidr.parse('203.0.113.7')!;
      expect(routes.any((r) => r.contains(endpoint)), isFalse);
      expect(routes.any((r) => r.contains(Cidr.parse('203.0.113.8')!)), isTrue);
      expect(routes.any((r) => r.contains(Cidr.parse('8.8.8.8')!)), isTrue);
      expect(routes.any((r) => r.contains(Cidr.parse('192.168.1.10')!)),
          isFalse);
      expect(routes.any((r) => r.contains(Cidr.parse('10.10.7.3')!)), isFalse);
    });

    test('parse rejects junk', () {
      expect(Cidr.parse('1.2.3'), isNull);
      expect(Cidr.parse('1.2.3.256'), isNull);
      expect(Cidr.parse('1.2.3.4/33'), isNull);
      expect(Cidr.parse('10.10.0.9/24').toString(), '10.10.0.0/24');
    });
  });

  group('LatencySample', () {
    test('median, jitter and loss', () {
      const s = LatencySample([30, 32, -1, 31, 90, 33]);
      expect(s.answered.length, 5);
      expect(s.lossPercent, closeTo(16.7, 0.1));
      expect(s.medianMs, 32);
      expect(s.minMs, 30);
      // |32-30| + |31-32| + |90-31| + |33-90| = 2+1+59+57 = 119 over 4
      expect(s.jitterMs, closeTo(29.75, 0.001));
    });

    test('a spiky route scores worse than a steady one with the same median',
        () {
      const steady = LatencySample([40, 41, 40, 42, 41]);
      const spiky = LatencySample([40, 90, 41, 20, 41]);
      expect(steady.medianMs, spiky.medianMs);
      expect(steady.score, lessThan(spiky.score));
    });

    test('no answers is unusable', () {
      const s = LatencySample([-1, -1]);
      expect(s.ok, isFalse);
      expect(s.medianMs, isNull);
      expect(s.score, double.infinity);
    });
  });
}
