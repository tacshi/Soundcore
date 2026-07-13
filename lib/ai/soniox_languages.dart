class SonioxLanguage {
  const SonioxLanguage(this.code, this.name);

  final String code;
  final String name;

  String get label => '$name · $code';
}

/// Languages documented for Soniox speech translation.
const sonioxLanguages = <SonioxLanguage>[
  SonioxLanguage('af', 'Afrikaans'),
  SonioxLanguage('sq', 'Albanian'),
  SonioxLanguage('ar', 'Arabic'),
  SonioxLanguage('az', 'Azerbaijani'),
  SonioxLanguage('eu', 'Basque'),
  SonioxLanguage('be', 'Belarusian'),
  SonioxLanguage('bn', 'Bengali'),
  SonioxLanguage('bs', 'Bosnian'),
  SonioxLanguage('bg', 'Bulgarian'),
  SonioxLanguage('ca', 'Catalan'),
  SonioxLanguage('zh', '中文'),
  SonioxLanguage('hr', 'Croatian'),
  SonioxLanguage('cs', 'Czech'),
  SonioxLanguage('da', 'Danish'),
  SonioxLanguage('nl', 'Dutch'),
  SonioxLanguage('en', 'English'),
  SonioxLanguage('et', 'Estonian'),
  SonioxLanguage('fi', 'Finnish'),
  SonioxLanguage('fr', 'French'),
  SonioxLanguage('gl', 'Galician'),
  SonioxLanguage('de', 'German'),
  SonioxLanguage('el', 'Greek'),
  SonioxLanguage('gu', 'Gujarati'),
  SonioxLanguage('he', 'Hebrew'),
  SonioxLanguage('hi', 'Hindi'),
  SonioxLanguage('hu', 'Hungarian'),
  SonioxLanguage('id', 'Indonesian'),
  SonioxLanguage('it', 'Italian'),
  SonioxLanguage('ja', '日本語'),
  SonioxLanguage('kn', 'Kannada'),
  SonioxLanguage('kk', 'Kazakh'),
  SonioxLanguage('ko', '한국어'),
  SonioxLanguage('lv', 'Latvian'),
  SonioxLanguage('lt', 'Lithuanian'),
  SonioxLanguage('mk', 'Macedonian'),
  SonioxLanguage('ms', 'Malay'),
  SonioxLanguage('ml', 'Malayalam'),
  SonioxLanguage('mr', 'Marathi'),
  SonioxLanguage('no', 'Norwegian'),
  SonioxLanguage('fa', 'Persian'),
  SonioxLanguage('pl', 'Polish'),
  SonioxLanguage('pt', 'Portuguese'),
  SonioxLanguage('pa', 'Punjabi'),
  SonioxLanguage('ro', 'Romanian'),
  SonioxLanguage('ru', 'Russian'),
  SonioxLanguage('sr', 'Serbian'),
  SonioxLanguage('sk', 'Slovak'),
  SonioxLanguage('sl', 'Slovenian'),
  SonioxLanguage('es', 'Spanish'),
  SonioxLanguage('sw', 'Swahili'),
  SonioxLanguage('sv', 'Swedish'),
  SonioxLanguage('tl', 'Tagalog'),
  SonioxLanguage('ta', 'Tamil'),
  SonioxLanguage('te', 'Telugu'),
  SonioxLanguage('th', 'Thai'),
  SonioxLanguage('tr', 'Turkish'),
  SonioxLanguage('uk', 'Ukrainian'),
  SonioxLanguage('ur', 'Urdu'),
  SonioxLanguage('vi', 'Vietnamese'),
  SonioxLanguage('cy', 'Welsh'),
];

SonioxLanguage sonioxLanguageFor(String code) {
  final normalized = code.trim().toLowerCase();
  return sonioxLanguages.firstWhere(
    (language) => language.code == normalized,
    orElse: () => SonioxLanguage(normalized, normalized.toUpperCase()),
  );
}

bool isSonioxLanguage(String code) {
  final normalized = code.trim().toLowerCase();
  return sonioxLanguages.any((language) => language.code == normalized);
}
