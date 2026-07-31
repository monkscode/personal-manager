import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String projectPath(List<String> segments) =>
    segments.join(Platform.pathSeparator);

String readProjectFile(List<String> segments) =>
    File(projectPath(segments)).readAsStringSync();

bool pubspecHasDependency(String pubspec, String packageName) {
  final dependencyPattern = RegExp(
    '^  ${RegExp.escape(packageName)}:',
    multiLine: true,
  );
  return dependencyPattern.hasMatch(pubspec);
}

bool hasSmsDataExtractionExclusions(String rulesXml) {
  final excludeTags = RegExp(
    r'<exclude\b[^>]*>',
    caseSensitive: false,
  ).allMatches(rulesXml).map((match) => match.group(0)!);

  var excludesDatabase = false;
  var excludesSharedPrefs = false;

  for (final tag in excludeTags) {
    if (_attributeEquals(tag, 'domain', 'database')) {
      excludesDatabase = true;
    }
    if (_attributeEquals(tag, 'domain', 'sharedpref')) {
      excludesSharedPrefs = true;
    }
  }

  return excludesDatabase && excludesSharedPrefs;
}

bool _attributeEquals(String tag, String name, String value) {
  final attributePattern = RegExp(
    '$name\\s*=\\s*["\']${RegExp.escape(value)}["\']',
    caseSensitive: false,
  );
  return attributePattern.hasMatch(tag);
}

Set<String> declaredPermissions(String manifest) {
  final pattern = RegExp(
    r'<uses-permission\b[^>]*android:name\s*=\s*"([^"]+)"',
    caseSensitive: false,
  );
  return pattern.allMatches(manifest).map((match) => match.group(1)!).toSet();
}

void main() {
  group('SMS platform boundary (reader enabled)', () {
    String readManifest() => readProjectFile([
      'android',
      'app',
      'src',
      'main',
      'AndroidManifest.xml',
    ]);

    test('declares READ_SMS now that the reader intentionally ships', () {
      expect(
        declaredPermissions(readManifest()),
        contains('android.permission.READ_SMS'),
      );
    });

    test('declares no permissions beyond INTERNET and READ_SMS', () {
      expect(declaredPermissions(readManifest()), <String>{
        'android.permission.INTERNET',
        'android.permission.READ_SMS',
      });
    });

    test('depends on the SMS reader stack now that the reader ships', () {
      final pubspec = readProjectFile(['pubspec.yaml']);

      expect(pubspecHasDependency(pubspec, 'flutter_sms_inbox'), isTrue);
      expect(pubspecHasDependency(pubspec, 'permission_handler'), isTrue);
    });

    test('keeps Android backup hardened while SMS storage ships', () {
      final manifest = readManifest();

      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));

      final dataExtractionRules = File(
        projectPath([
          'android',
          'app',
          'src',
          'main',
          'res',
          'xml',
          'data_extraction_rules.xml',
        ]),
      );
      final backupRules = File(
        projectPath([
          'android',
          'app',
          'src',
          'main',
          'res',
          'xml',
          'backup_rules.xml',
        ]),
      );

      expect(dataExtractionRules.existsSync(), isTrue);
      expect(backupRules.existsSync(), isTrue);
      expect(
        hasSmsDataExtractionExclusions(dataExtractionRules.readAsStringSync()),
        isTrue,
      );
      expect(
        hasSmsDataExtractionExclusions(backupRules.readAsStringSync()),
        isTrue,
      );
    });

    test('rejects data extraction rules that do not exclude SMS storage', () {
      const allowAllRules = '''
<data-extraction-rules>
  <cloud-backup>
    <include domain="database" path="."/>
    <include domain="sharedpref" path="."/>
  </cloud-backup>
</data-extraction-rules>
''';

      expect(hasSmsDataExtractionExclusions(allowAllRules), isFalse);
    });

    test('accepts data extraction rules that exclude DB and shared prefs', () {
      const excludingRules = '''
<data-extraction-rules>
  <cloud-backup>
    <exclude domain="database" path="transactions.db"/>
    <exclude domain="sharedpref" path="."/>
  </cloud-backup>
  <device-transfer>
    <exclude domain="database" path="transactions.db"/>
    <exclude domain="sharedpref" path="."/>
  </device-transfer>
</data-extraction-rules>
''';

      expect(hasSmsDataExtractionExclusions(excludingRules), isTrue);
    });
  });
}
