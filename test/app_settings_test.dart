import 'package:anker_recorder/state/app_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('communication settings use backward-compatible defaults', () {
    final settings = AppSettings.fromJson(const {});

    expect(settings.communicationModeEnabled, isFalse);
    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
  });

  test('communication settings round-trip through JSON', () {
    const original = AppSettings(
      communicationModeEnabled: true,
      ownerLanguage: 'ja',
      guestLanguage: 'ko',
    );

    final restored = AppSettings.fromJson(original.toJson());

    expect(restored.communicationModeEnabled, isTrue);
    expect(restored.ownerLanguage, 'ja');
    expect(restored.guestLanguage, 'ko');
  });

  test('duplicate persisted languages fall back to a valid pair', () {
    final settings = AppSettings.fromJson(const {
      'communicationModeEnabled': true,
      'ownerLanguage': 'en',
      'guestLanguage': 'en',
    });

    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
  });
}
