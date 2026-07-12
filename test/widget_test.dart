import 'package:anker_recorder/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to home shell', (tester) async {
    await tester.pumpWidget(const AnkerRecorderApp());
    // Primary tab is Home (files / live), with bottom nav.
    expect(find.text('录音'), findsWidgets);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
