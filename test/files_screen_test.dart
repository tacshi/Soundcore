import 'dart:io';

import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/files_screen.dart';
import 'package:anker_recorder/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recording actions appear before rename on the flat row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const path = '/tmp/1783917051.wav';
    final controller = RecorderController(loadPersistedState: false)
      ..exportedPaths = [path]
      ..transcriptsByPath[path] = '测试转写';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );

    final save = find.byTooltip('保存录音和转写');
    final share = find.byTooltip('分享录音和转写');
    final rename = find.byTooltip('重命名');
    expect(save, findsOneWidget);
    expect(share, findsOneWidget);
    expect(rename, findsOneWidget);
    expect(tester.getCenter(save).dx, lessThan(tester.getCenter(share).dx));
    expect(tester.getCenter(share).dx, lessThan(tester.getCenter(rename).dx));
    expect(find.byType(SurfaceCard), findsNothing);
  });

  test(
    'share payload always includes audio and includes transcript when set',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'anker-recorder-share-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final stem = DateTime.now().microsecondsSinceEpoch;
      final audio = File('${directory.path}/$stem.wav');
      await audio.writeAsBytes([1, 2, 3]);

      final controller = RecorderController(loadPersistedState: false)
        ..transcriptsByPath[audio.path] = '第一行<end>第二行';
      addTearDown(controller.dispose);

      final paths = await controller.prepareLocalSharePaths([audio.path]);
      addTearDown(() => File(paths.last).delete());

      expect(paths.first, audio.path);
      expect(paths, hasLength(2));
      expect(await File(paths.last).readAsString(), '第一行\n第二行');
    },
  );
}
