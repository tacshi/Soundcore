import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/app_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MOSS credentials round-trip independently of Soniox', () {
    final settings = AppSettings.fromJson({
      'speechProvider': 'moss',
      'mossApiKey': 'moss-key',
      'sonioxApiKey': 'soniox-key',
    });
    expect(settings.speechProvider?.name, 'moss');
    expect(settings.toJson()['mossApiKey'], 'moss-key');
    final cleared = settings.copyWith(clearMoss: true);
    expect(cleared.mossApiKey, isNull);
    expect(cleared.sonioxApiKey, 'soniox-key');
    expect(AppSettings.fromJson({}).mossApiKey, isNull);
  });

  test('translation settings use backward-compatible defaults', () {
    final settings = AppSettings.fromJson(const {});

    expect(settings.sttMode, SttDisplayMode.transcription);
    expect(settings.translationTargetLanguage, 'zh');
    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
    expect(settings.transcriptLanguage, 'auto');
  });

  test('translation settings round-trip through JSON', () {
    const original = AppSettings(
      sttMode: SttDisplayMode.translation,
      translationTargetLanguage: 'ja',
      ownerLanguage: 'ja',
      guestLanguage: 'ko',
    );

    final restored = AppSettings.fromJson(original.toJson());

    expect(restored.sttMode, SttDisplayMode.translation);
    expect(restored.translationTargetLanguage, 'ja');
    expect(restored.ownerLanguage, 'ja');
    expect(restored.guestLanguage, 'ko');
  });

  test('legacy communication switch migrates to conversation mode', () {
    final settings = AppSettings.fromJson(const {
      'communicationModeEnabled': true,
    });

    expect(settings.sttMode, SttDisplayMode.conversation);
  });

  test('explicit display mode takes precedence over legacy switch', () {
    final settings = AppSettings.fromJson(const {
      'sttMode': 'translation',
      'communicationModeEnabled': true,
    });

    expect(settings.sttMode, SttDisplayMode.translation);
  });

  test('duplicate persisted languages fall back to a valid pair', () {
    final settings = AppSettings.fromJson(const {
      'sttMode': 'conversation',
      'ownerLanguage': 'en',
      'guestLanguage': 'en',
    });

    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
  });

  test('legacy xAI settings are ignored when settings are rewritten', () {
    final settings = AppSettings.fromJson(const {
      'sttProvider': 'xai',
      'xaiApiKey': 'obsolete',
    });

    expect(settings.toJson(), isNot(contains('sttProvider')));
    expect(settings.toJson(), isNot(contains('xaiApiKey')));
  });
}
