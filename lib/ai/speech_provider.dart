enum SttProvider {
  apple('Apple 设备端'),
  soniox('Soniox'),
  moss('MOSS Pro');

  const SttProvider(this.label);
  final String label;

  static SttProvider? parse(Object? value) {
    for (final provider in values) {
      if (provider.name == value) return provider;
    }
    return null;
  }
}

SttProvider initialSpeechProvider({
  required SttProvider? saved,
  required bool appleSupported,
  required bool sonioxConfigured,
}) =>
    saved ??
    (appleSupported && !sonioxConfigured
        ? SttProvider.apple
        : SttProvider.soniox);
