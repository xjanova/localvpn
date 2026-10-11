import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/widgets/m3/m3.dart';

Widget _host(M3Palette palette, Widget child) => MaterialApp(
      theme: buildM3Theme(palette),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final palette in [M3Palette.night, M3Palette.sky]) {
    final name = palette.isNight ? 'night' : 'sky';

    testWidgets('kit widgets build ($name)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(
        palette,
        SingleChildScrollView(
          child: Column(
            children: [
              GlassPanel(
                child: Column(
                  children: [
                    const M3CardHeader(title: 'การ์ด', icon3d: M3Icons.members),
                    GlossButton(label: 'เชื่อมต่อ', onPressed: () => taps++),
                    const GlossButton(
                        label: 'ปิด', variant: GlossVariant.red),
                    const M3Tag('ออนไลน์', tone: M3Tone.green, dot: true),
                    M3Switch(value: true, onChanged: (_) {}),
                    const M3ProgressBar(value: 0.4),
                    const M3KeyValue('Virtual IP', '10.10.0.2', mono: true),
                  ],
                ),
              ),
              const ProBadge(
                  kind: ProBadgeKind.pro, main: 'PRO', sub: 'ตลอดชีพ'),
            ],
          ),
        ),
      ));
      await tester.tap(find.text('เชื่อมต่อ'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(taps, 1);
      // A disabled button ignores taps.
      await tester.tap(find.text('ปิด'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('confirm dialog returns the choice ($name)', (tester) async {
      bool? answer;
      await tester.pumpWidget(_host(
        palette,
        Builder(
          builder: (context) => GlossButton(
            label: 'ลบ',
            onPressed: () async {
              answer = await m3Confirm(context,
                  title: 'ลบวง?', confirmLabel: 'ลบเลย', destructive: true);
            },
          ),
        ),
      ));
      await tester.tap(find.text('ลบ'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('ลบเลย'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(answer, isTrue);
    });
  }
}
