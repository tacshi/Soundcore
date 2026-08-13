import 'dart:async';

import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/device_screen.dart';
import 'package:anker_recorder/ui/screens/home_screen.dart';
import 'package:anker_recorder/ui/screens/settings_screen.dart';
import 'package:anker_recorder/ui/shell.dart';
import 'package:anker_recorder/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disconnected recorder cannot leave the live page active', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller
      ..connected = true
      ..recording = true;
    expect(controller.isLiveSession, isTrue);

    controller
      ..recording = false
      ..streamingSttActive = true;
    expect(controller.isLiveSession, isTrue);

    controller
      ..connected = false
      ..recording = true;
    expect(controller.isLiveSession, isFalse);
  });

  testWidgets('Home remains a flat transcript view when auto STT is disabled', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = false;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('录音中'), findsNothing);
    expect(find.text('自动转写已关闭，可在「设置」中开启。'), findsOneWidget);
    expect(find.text('即时转写 · Soniox'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('live-session-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('copy-live-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('clear-live-transcript')), findsNothing);
    expect(
      find.byKey(const ValueKey('live-transcript-scroll')),
      findsOneWidget,
    );
    expect(find.byType(SurfaceCard), findsNothing);

    controller
      ..autoTranscribe = true
      ..notifyListeners();
    await tester.pump();
    expect(find.text('实时同步转写'), findsNothing);
    expect(find.text('即时转写 · Soniox'), findsOneWidget);
    if (!controller.sttConfigured) {
      expect(find.text('请在「设置」中配置 SONIOX_API_KEY'), findsOneWidget);
    }
  });

  testWidgets('Home displays recording history tabs while idle', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byKey(const ValueKey('live-transcript-scroll')), findsNothing);
    expect(
      find.byKey(const ValueKey('live-transcript-placeholder')),
      findsNothing,
    );
    expect(find.text('已导出'), findsOneWidget);
    expect(find.text('设备端'), findsOneWidget);
  });

  testWidgets('Home stays on transcript until live finalization finishes', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..transcript = 'Current live session';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: AppShell()),
      ),
    );

    expect(
      find.byKey(const ValueKey('live-transcript-scroll')),
      findsOneWidget,
    );
    expect(find.text('已导出'), findsNothing);
    expect(find.text('首页'), findsNothing);
    expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsNothing);
    expect(find.byKey(const ValueKey('pause-recording')), findsOneWidget);

    controller
      ..recording = false
      ..streamingSttActive = true
      ..notifyListeners();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('live-transcript-scroll')),
      findsOneWidget,
    );
    expect(find.text('已导出'), findsNothing);
    expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsNothing);
    expect(find.byKey(const ValueKey('pause-recording')), findsNothing);
    expect(find.byKey(const ValueKey('start-recording')), findsNothing);

    controller
      ..streamingSttActive = false
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-transcript-scroll')), findsNothing);
    expect(find.text('已导出'), findsOneWidget);
    expect(find.text('设备端'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('转写'), findsNothing);
    expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsOneWidget);
  });

  testWidgets('a live session takes over from another tab', (tester) async {
    final controller = RecorderController(loadPersistedState: false)
      ..connected = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: AppShell()),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-device')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('device-battery-section')),
      findsOneWidget,
    );

    controller
      ..recording = true
      ..notifyListeners();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('live-transcript-scroll')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsNothing);
  });

  testWidgets('live transcript always follows newly appended text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final initial = List.generate(
      50,
      (index) => 'Current session transcript line $index',
    ).join('\n');
    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..transcript = initial;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('live-transcript-scroll')),
    );
    final scrollController = scrollView.controller!;
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    expect(
      scrollController.offset,
      moreOrLessEquals(scrollController.position.maxScrollExtent),
    );

    scrollController.jumpTo(0);
    controller
      ..transcript = '$initial\nNewest incoming transcript line'
      ..notifyListeners();
    await tester.pump();

    expect(
      scrollController.offset,
      moreOrLessEquals(scrollController.position.maxScrollExtent),
    );

    expect(find.byKey(const ValueKey('copy-live-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('clear-live-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('pause-recording')), findsOneWidget);

    controller.clearTranscript();
    await tester.pump();
    expect(scrollController.position.maxScrollExtent, 0);
    expect(scrollController.offset, 0);
  });

  test('Soniox translation modes enforce distinct languages', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller.autoTranscribe = true;
    controller.setSttMode(SttDisplayMode.translation);
    expect(controller.translationModeActive, isTrue);

    controller.translationTurns = const [
      SttTranslationTurn(
        targetLanguage: 'zh',
        sourceLanguage: 'en',
        text: '你好',
        isFinal: true,
      ),
    ];
    controller.setTranslationTargetLanguage('ja');
    expect(controller.translationTargetLanguage, 'ja');
    expect(controller.translationTurns, isEmpty);

    controller.setSttMode(SttDisplayMode.conversation);
    expect(controller.communicationModeActive, isTrue);

    controller.setGuestLanguage('zh');
    expect(controller.guestLanguage, 'en');

    controller.swapCommunicationLanguages();
    expect(controller.ownerLanguage, 'en');
    expect(controller.guestLanguage, 'zh');

    controller.setAutoTranscribe(false);
    expect(controller.sttMode, SttDisplayMode.transcription);
    expect(controller.sonioxTranslationModeAvailable, isFalse);
  });

  testWidgets('settings selector enables Soniox translation mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..autoTranscribe = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    expect(find.text('设置'), findsNothing);
    expect(find.text('服务商'), findsNothing);
    expect(find.textContaining('xAI'), findsNothing);
    expect(find.byKey(const ValueKey('apikey-soniox')), findsOneWidget);
    final languageSelector = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('transcript-language-selector')),
    );
    expect(languageSelector.items!.first.value, 'auto');
    expect(languageSelector.items!.first.child, isA<Text>());
    expect((languageSelector.items!.first.child as Text).data, '自动');
    await tester.ensureVisible(
      find.byKey(const ValueKey('stt-display-mode-selector')),
    );
    await tester.pump();

    final selector = tester.widget<SegmentedButton<SttDisplayMode>>(
      find.byKey(const ValueKey('stt-display-mode-selector')),
    );
    selector.onSelectionChanged?.call({SttDisplayMode.translation});
    await tester.pump();

    expect(controller.sttMode, SttDisplayMode.translation);
    expect(find.text('目标语言'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-transfer-group')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-stt-group')), findsOneWidget);
    expect(find.byType(SurfaceCard), findsNothing);

    languageSelector.onChanged?.call('en');
    await tester.pump();
    expect(controller.transcriptLanguage, 'en');
  });

  testWidgets('connected Device uses flat management sections', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..connected = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: DeviceScreen()),
      ),
    );

    for (final key in [
      'device-battery-section',
      'device-recording-section',
      'device-pairing-section',
      'device-info-section',
      'device-danger-section',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(find.byType(SurfaceCard), findsNothing);
  });

  testWidgets('translation mode shows latest translation and source text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..sttMode = SttDisplayMode.translation
      ..translationTargetLanguage = 'zh'
      ..translationTurns = const [
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '过时的翻译',
          isFinal: true,
          sourceText: 'Old source',
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '上上句',
          isFinal: true,
          sourceText: 'Earlier source',
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '上一句',
          isFinal: true,
          sourceText: 'Previous source',
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '最新翻译',
          isFinal: false,
          sourceText: 'Latest original',
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('即时翻译 · 中文'), findsOneWidget);
    expect(find.text('最新翻译'), findsOneWidget);
    expect(find.text('上一句'), findsOneWidget);
    expect(find.text('上上句'), findsOneWidget);
    expect(find.text('过时的翻译'), findsOneWidget);
    expect(find.text('Latest original'), findsOneWidget);
    expect(find.text('原文 · English'), findsOneWidget);

    controller
      ..pendingTranslationSource = const SttSourceChunk(
        language: 'fr',
        text: 'Bonjour',
      )
      ..notifyListeners();
    await tester.pump();
    expect(find.text('最新翻译'), findsOneWidget);
    expect(find.text('Bonjour'), findsOneWidget);
    expect(find.text('待翻译原文 · French'), findsOneWidget);

    controller
      ..transcriptError = '翻译模式错误：test'
      ..pendingTranslationSource = null
      ..notifyListeners();
    await tester.pump();
    expect(find.text('翻译模式错误：test'), findsOneWidget);
    expect(find.text('最新翻译'), findsOneWidget);

    controller
      ..transcriptError = null
      ..translationTurns = const []
      ..transcript = 'New source text'
      ..notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('translation-pending')), findsOneWidget);
    expect(find.text('New source text'), findsOneWidget);
    expect(find.text('正在翻译…'), findsOneWidget);
  });

  testWidgets('translation canvas follows new turns and pending source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final initialTurns = List.generate(
      30,
      (index) => SttTranslationTurn(
        targetLanguage: 'zh',
        sourceLanguage: 'en',
        text: 'Current session translated line $index with enough text',
        isFinal: true,
        sourceText: 'Source line $index',
      ),
    );
    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..sttMode = SttDisplayMode.translation
      ..translationTargetLanguage = 'zh'
      ..translationTurns = initialTurns;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('live-transcript-scroll')),
    );
    final scrollController = scrollView.controller!;
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    expect(
      scrollController.offset,
      moreOrLessEquals(scrollController.position.maxScrollExtent),
    );

    scrollController.jumpTo(0);
    controller
      ..translationTurns = [
        ...initialTurns,
        const SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: 'Newest translated line',
          isFinal: false,
          sourceText: 'Newest source line',
        ),
      ]
      ..notifyListeners();
    await tester.pump();
    expect(
      scrollController.offset,
      moreOrLessEquals(scrollController.position.maxScrollExtent),
    );

    scrollController.jumpTo(0);
    controller
      ..pendingTranslationSource = const SttSourceChunk(
        language: 'en',
        text: 'Newest pending source',
      )
      ..notifyListeners();
    await tester.pump();
    expect(
      scrollController.offset,
      moreOrLessEquals(scrollController.position.maxScrollExtent),
    );
  });

  testWidgets('communication mode replaces shell with equal rotated panels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..sttMode = SttDisplayMode.conversation
      ..ownerLanguage = 'zh'
      ..guestLanguage = 'en'
      ..ownerTranslationTurns = const [
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '第一句',
          isFinal: true,
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '第二句',
          isFinal: true,
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '最新一句',
          isFinal: false,
        ),
      ]
      ..guestTranslationTurns = const [
        SttTranslationTurn(
          targetLanguage: 'en',
          sourceLanguage: 'zh',
          text: 'Latest translation',
          isFinal: true,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: AppShell()),
      ),
    );

    expect(find.text('首页'), findsNothing);
    expect(find.byKey(const ValueKey('communication-owner-panel')), findsOne);
    expect(find.byKey(const ValueKey('communication-guest-panel')), findsOne);
    expect(find.text('第一句'), findsOne);
    expect(find.text('第二句'), findsOne);
    expect(find.text('最新一句'), findsOne);
    expect(find.text('Latest translation'), findsOne);

    final ownerSize = tester.getSize(
      find.byKey(const ValueKey('communication-owner-panel')),
    );
    final guestSize = tester.getSize(
      find.byKey(const ValueKey('communication-guest-panel')),
    );
    expect(ownerSize.height, moreOrLessEquals(guestSize.height));

    final rotation = tester.widget<RotatedBox>(
      find.byKey(const ValueKey('communication-guest-rotation')),
    );
    expect(rotation.quarterTurns, 2);

    controller
      ..transcriptError = '交流模式错误：test'
      ..notifyListeners();
    await tester.pump();
    expect(find.text('交流模式错误：test'), findsOneWidget);

    controller
      ..transcriptError = null
      ..ownerTranslationTurns = const []
      ..guestTranslationTurns = const []
      ..notifyListeners();
    await tester.pump();
    expect(find.text('…'), findsNWidgets(2));

    controller
      ..recording = false
      ..streamingSttActive = false
      ..notifyListeners();
    await tester.pump();
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('recording shortcut returns the shell to Home', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: AppShell()),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(find.text('AI 转写'), findsOneWidget);

    unawaited(controller.requestRecordingFromShortcut());
    await tester.pump();
    await tester.pump();

    expect(find.text('AI 转写'), findsNothing);
    expect(find.text('未连接设备'), findsOneWidget);
  });
}
