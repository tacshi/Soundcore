import 'dart:io';

import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/files_screen.dart';
import 'package:anker_recorder/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpFiles(
    WidgetTester tester,
    RecorderController controller, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();
  }

  testWidgets('recording actions appear before rename on the flat row', (
    tester,
  ) async {
    const path = '/tmp/1783917051.wav';
    final controller = RecorderController(loadPersistedState: false)
      ..exportedPaths = [path]
      ..transcriptsByPath[path] = '测试转写';
    addTearDown(controller.dispose);

    await pumpFiles(tester, controller);

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

  testWidgets(
    'speaker chips scroll independently and rename every transcript surface',
    (tester) async {
      const path = '/tmp/1783917051.wav';
      final transcript = List.generate(
        8,
        (index) => '说话人 ${index + 1}：第 ${index + 1} 位说话人',
      ).join('\n');
      final controller = RecorderController(loadPersistedState: false)
        ..exportedPaths = [path]
        ..expandedLocalPath = path
        ..transcriptsByPath[path] = transcript;
      controller.setSonioxApiKey('test-key');
      addTearDown(controller.dispose);

      await pumpFiles(tester, controller);

      final scroll = find.byKey(ValueKey('speaker-label-scroll-$path'));
      final retranscribe = find.byKey(ValueKey('retranscribe-$path'));
      expect(scroll, findsOneWidget);
      expect(retranscribe, findsOneWidget);
      expect(
        tester.getCenter(retranscribe).dx,
        greaterThan(tester.getCenter(scroll).dx),
      );
      expect(tester.takeException(), isNull);

      final scrollable = find.descendant(
        of: scroll,
        matching: find.byType(Scrollable),
      );
      final before = tester.state<ScrollableState>(scrollable).position.pixels;
      await tester.drag(scroll, const Offset(-180, 0));
      await tester.pumpAndSettle();
      final after = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(after, greaterThan(before));
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pump();

      await tester.tap(find.byKey(ValueKey('speaker-label-$path-1')));
      await tester.pumpAndSettle();
      expect(find.text('重命名说话人'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('speaker-name-input')),
        '张三：',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(controller.transcriptForPath(path), startsWith('张三：第 1 位说话人'));
      expect(find.text('张三'), findsOneWidget);

      controller.toggleLocalExpanded(path);
      await tester.pump();
      expect(find.textContaining('张三：第 1 位说话人'), findsOneWidget);
    },
  );

  testWidgets('retranscription remains one confirmed action on the right', (
    tester,
  ) async {
    const path = '/tmp/1783917051.wav';
    final controller = _TrackingRecorderController()
      ..exportedPaths = [path]
      ..expandedLocalPath = path
      ..transcriptsByPath[path] = '说话人 1：测试';
    controller.setSonioxApiKey('test-key');
    addTearDown(controller.dispose);

    await pumpFiles(tester, controller);

    final button = find.byKey(ValueKey('retranscribe-$path'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('重新转写？'), findsOneWidget);
    expect(find.textContaining('自定义说话人姓名'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(controller.transcribeCalls, 0);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '重新转写'));
    await tester.pumpAndSettle();
    expect(controller.transcribeCalls, 1);
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
        ..transcriptsByPath[audio.path] = '说话人 1：第一行<end>说话人 1：第二行'
        ..speakerAliasesByPath[audio.path] = {'1': '张三'};
      addTearDown(controller.dispose);

      final paths = await controller.prepareLocalSharePaths([audio.path]);
      addTearDown(() => File(paths.last).delete());

      expect(paths.first, audio.path);
      expect(paths, hasLength(2));
      expect(await File(paths.last).readAsString(), '张三：第一行\n张三：第二行');
    },
  );
}

class _TrackingRecorderController extends RecorderController {
  _TrackingRecorderController() : super(loadPersistedState: false);

  int transcribeCalls = 0;

  @override
  Future<void> transcribeLocalFile(String path) async {
    transcribeCalls++;
  }
}
