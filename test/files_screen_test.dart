import 'dart:async';
import 'dart:io';

import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/protocol/models.dart';
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
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: FilesBody()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('compact rows open a detail page without expanding the library', (
    tester,
  ) async {
    const path = '/tmp/1783917051.wav';
    final controller = RecorderController(loadPersistedState: false)
      ..exportedPaths = [path]
      ..transcriptsByPath[path] = List.generate(
        100,
        (i) => '第 $i 段转写文本',
      ).join('\n');
    addTearDown(controller.dispose);
    await pumpFiles(tester, controller);
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('recording-preview-$path')),
    );
    expect(preview.maxLines, 2);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.byType(SurfaceCard), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recording-row-$path')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多操作'), findsOneWidget);
    expect(find.byTooltip('复制原文'), findsOneWidget);
    expect(find.text('第 0 段转写文本'), findsOneWidget);
    expect(find.text('第 99 段转写文本'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recording-preview-$path')),
      findsOneWidget,
    );
  });

  for (final device in [false, true]) {
    for (final populated in [false, true]) {
      testWidgets(
        'pull refreshes ${device ? 'device' : 'local'} ${populated ? 'short' : 'empty'} list',
        (tester) async {
          final c = _RefreshRecorderController()..connected = true;
          if (populated) {
            c.exportedPaths = ['/tmp/1783917051.wav'];
            c.files = [OfflineFileEntry(fileId: 1783917051, sizeBytes: 160)];
          }
          addTearDown(c.dispose);
          await pumpFiles(tester, c);
          if (device) {
            await tester.tap(find.text(populated ? '设备端 (1)' : '设备端'));
            await tester.pumpAndSettle();
          }
          expect(find.byTooltip('刷新'), findsNothing);
          expect(find.text('获取列表'), findsNothing);
          final refresh = find.byKey(
            ValueKey(
              device ? 'device-recordings-refresh' : 'local-recordings-refresh',
            ),
          );
          await tester.drag(refresh, const Offset(0, 350));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(c.deviceRefreshes, device ? 1 : 0);
          expect(c.localRefreshes, device ? 0 : 1);
          expect(find.byType(RefreshProgressIndicator), findsOneWidget);
          c.finished.complete();
          await tester.pumpAndSettle();
          expect(find.byType(RefreshProgressIndicator), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'download-all action is absent when every device recording is local',
    (tester) async {
      const path = '/tmp/1783917051.wav';
      final c = RecorderController(loadPersistedState: false)
        ..connected = true
        ..exportedPaths = [path]
        ..files = [OfflineFileEntry(fileId: 1783917051, sizeBytes: 160)]
        ..localPathsByFileId[1783917051] = path;
      addTearDown(c.dispose);
      await pumpFiles(tester, c);
      await tester.tap(find.text('设备端 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('全部已下载'), findsNothing);
      expect(find.text('通过 Wi-Fi 下载全部'), findsNothing);
      expect(find.byTooltip('刷新'), findsNothing);
    },
  );

  testWidgets('speaker names use one menu action and update the recording', (
    tester,
  ) async {
    const path = '/tmp/1783917051.wav';
    final controller = RecorderController(loadPersistedState: false)
      ..exportedPaths = [path]
      ..transcriptsByPath[path] = '说话人 1：第一句话\n说话人 2：第二句话';
    addTearDown(controller.dispose);
    await pumpFiles(tester, controller);
    await tester.tap(find.byKey(const ValueKey('recording-row-$path')));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('说话人姓名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('说话人 1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('speaker-name-input')),
      '张三：',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(controller.transcriptForPath(path), startsWith('张三：第一句话'));
    expect(find.text('张三：第一句话'), findsOneWidget);
  });

  testWidgets(
    'retranscription is confirmed before replacing an existing result',
    (tester) async {
      const path = '/tmp/1783917051.wav';
      final controller = _TrackingRecorderController()
        ..exportedPaths = [path]
        ..transcriptsByPath[path] = '说话人 1：测试';
      controller.setSonioxApiKey('test-key');
      addTearDown(controller.dispose);
      await pumpFiles(tester, controller);
      await tester.tap(find.byKey(const ValueKey('recording-row-$path')));
      await tester.pumpAndSettle();
      Future<void> confirmDialog() async {
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新转写'));
        await tester.pumpAndSettle();
      }

      await confirmDialog();
      expect(find.text('重新转写？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(controller.transcribeCalls, 0);
      await confirmDialog();
      await tester.tap(find.widgetWithText(FilledButton, '重新转写'));
      await tester.pumpAndSettle();
      expect(controller.transcribeCalls, 1);
    },
  );

  for (final variant in [
    (const Size(393, 852), 1.0),
    (const Size(320, 740), 2.0),
  ]) {
    testWidgets(
      'long press selects rows and keeps batch actions inline at ${variant.$2}x',
      (tester) async {
        const path = '/tmp/1783917051.wav';
        final c = RecorderController(loadPersistedState: false)
          ..connected = true
          ..exportedPaths = [path]
          ..files = [
            OfflineFileEntry(fileId: 1783917051, sizeBytes: 160),
            OfflineFileEntry(fileId: 1783917052, sizeBytes: 160),
          ];
        addTearDown(c.dispose);
        await pumpFiles(tester, c, size: variant.$1, scale: variant.$2);
        expect(find.text('批量管理'), findsNothing);
        await tester.longPress(
          find.byKey(const ValueKey('recording-row-$path')),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        expect(find.byTooltip('更多操作'), findsNothing);
        expect(find.text('保存所选'), findsNothing);
        expect(find.text('删除所选'), findsNothing);
        final save = find.byTooltip('保存所选');
        final delete = find.byTooltip('删除所选');
        final cancel = find.byTooltip('取消选择');
        expect(tester.getCenter(save).dy, tester.getCenter(cancel).dy);
        expect(tester.getCenter(delete).dy, tester.getCenter(cancel).dy);
        expect(tester.getSize(save).width, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        // Repeating the gesture retains the selected row; it never opens detail.
        await tester.longPress(
          find.byKey(const ValueKey('recording-row-$path')),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        final compact = variant.$2 > 1;
        await tester.tap(compact ? find.byTooltip('清空') : find.text('清空'));
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.save_alt_rounded),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(compact ? find.byTooltip('全选') : find.text('全选'));
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        await tester.tap(cancel);
        await tester.tap(find.text('设备端 (2)'));
        await tester.pumpAndSettle();
        expect(find.text('批量管理'), findsNothing);
        await tester.longPress(
          find.byKey(const ValueKey('device-recording-row-1783917051')),
        );
        await tester.pumpAndSettle();
        expect(c.selectedFileIds, {1783917051});
        await tester.tap(compact ? find.byTooltip('全选') : find.text('全选'));
        await tester.pumpAndSettle();
        expect(c.selectedFileIds, {1783917051, 1783917052});
        expect(
          tester.getCenter(find.byTooltip('下载所选')).dy,
          tester.getCenter(find.byTooltip('删除所选')).dy,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
  Future<void> transcribeRecording(
    RecordingReference reference, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    transcribeCalls++;
  }
}

class _RefreshRecorderController extends RecorderController {
  _RefreshRecorderController() : super(loadPersistedState: false);
  final finished = Completer<void>();
  int localRefreshes = 0;
  int deviceRefreshes = 0;

  @override
  Future<void> refreshLocalFiles() {
    localRefreshes++;
    return finished.future;
  }

  @override
  Future<void> refreshDeviceFiles() {
    deviceRefreshes++;
    return finished.future;
  }
}
