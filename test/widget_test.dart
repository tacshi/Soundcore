import 'package:anker_recorder/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to home shell', (tester) async {
    await tester.pumpWidget(const SoundcoreManagerApp());
    // Primary tab is Home with recording history while idle.
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    final nav = tester.widget<Container>(
      find.byKey(const ValueKey('bottom-navigation-bar')),
    );
    final decoration = nav.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.borderRadius, isNull);

    final activeIndicator = find.byKey(const ValueKey('active-tab-indicator'));
    expect(activeIndicator, findsOneWidget);
    expect(
      tester.getCenter(activeIndicator).dy,
      greaterThan(tester.getCenter(find.text('首页')).dy),
    );
  });
}
