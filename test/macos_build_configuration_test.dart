import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS Flutter assemble phase is safe after moving the project', () {
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final phase = RegExp(
      r'33CC111E2044C6BF0003C045 /\* ShellScript \*/ = \{(.*?)\n\t\t\};',
      dotAll: true,
    ).firstMatch(project)?.group(1);

    expect(phase, isNotNull);
    expect(phase, contains('alwaysOutOfDate = 1;'));
    expect(phase, isNot(contains('FlutterInputs.xcfilelist')));
    expect(phase, isNot(contains('FlutterOutputs.xcfilelist')));
  });
}
