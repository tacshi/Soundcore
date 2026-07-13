import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/home_screen.dart';
import 'package:anker_recorder/ui/screens/settings_screen.dart';
import 'package:anker_recorder/ui/shell.dart';
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

  testWidgets('disabled auto transcription hides the live transcript section', (
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

    expect(find.text('录音中'), findsOneWidget);
    expect(find.text('自动转写已关闭'), findsOneWidget);
    expect(find.text('录音中 · 实时同步转写'), findsNothing);
    expect(find.text('转写已关闭'), findsNothing);
    expect(find.text('转写预览'), findsNothing);

    controller
      ..autoTranscribe = true
      ..notifyListeners();
    await tester.pump();
    expect(find.text('实时同步转写'), findsOneWidget);
    expect(find.text('转写预览'), findsOneWidget);
  });

  test('translation modes enforce provider and distinct languages', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller
      ..autoTranscribe = true
      ..sttProvider = SttProvider.soniox;
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

    controller.setSttProvider(SttProvider.xai);
    expect(controller.sttMode, SttDisplayMode.transcription);
    expect(controller.sonioxTranslationModeAvailable, isFalse);
  });

  testWidgets('settings selector enables Soniox translation mode', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..autoTranscribe = true
      ..sttProvider = SttProvider.soniox;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
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

    controller.setSttProvider(SttProvider.xai);
    await tester.pump();
    expect(controller.sttMode, SttDisplayMode.transcription);
    expect(find.text('目标语言'), findsNothing);
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
      ..sttProvider = SttProvider.soniox
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

    expect(find.text('翻译预览 · 中文'), findsOneWidget);
    expect(find.text('最新翻译'), findsOneWidget);
    expect(find.text('上一句'), findsOneWidget);
    expect(find.text('上上句'), findsOneWidget);
    expect(find.text('过时的翻译'), findsNothing);
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
      ..sttProvider = SttProvider.soniox
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
}
