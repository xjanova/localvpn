import 'package:flutter_test/flutter_test.dart';

import 'package:localvpn/main.dart';

void main() {
  testWidgets('App starts with splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const LocalVPNApp());
    expect(find.text('LocalVPN'), findsOneWidget);
    expect(find.text('Virtual LAN over Internet'), findsOneWidget);
  });
}
