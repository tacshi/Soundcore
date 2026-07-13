import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/home_screen.dart';
import 'package:anker_recorder/ai/stt_types.dart';
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

  test('communication settings enforce provider and distinct languages', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller
      ..autoTranscribe = true
      ..sttProvider = SttProvider.soniox;
    controller.setCommunicationMode(true);
    expect(controller.communicationModeEnabled, isTrue);

    controller.setGuestLanguage('zh');
    expect(controller.guestLanguage, 'en');

    controller.swapCommunicationLanguages();
    expect(controller.ownerLanguage, 'en');
    expect(controller.guestLanguage, 'zh');

    controller.setSttProvider(SttProvider.xai);
    expect(controller.communicationModeEnabled, isFalse);
    expect(controller.communicationModeAvailable, isFalse);
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
      ..communicationModeEnabled = true
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
