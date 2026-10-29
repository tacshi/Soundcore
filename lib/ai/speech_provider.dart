enum SttProvider {
  apple('Apple 设备端'),
  soniox('Soniox'),
  moss('MOSS Pro'),
  xfyun('讯飞'),
  volc('火山引擎');

  const SttProvider(this.label);
  final String label;

  /// Providers that only transcribe saved files after recording ends.
  bool get fileOnly => this == moss || this == xfyun || this == volc;

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
