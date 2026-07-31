import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Documentation drift guard (spec §12 phase 10 / Phase J).
///
/// The SMS Actuals layer ships privacy-sensitive, distribution-limiting
/// behavior (`READ_SMS`, redacted-body storage, backup exclusions, sideload-only
/// status) and a salary-anchored dated cash-flow forecast. These facts MUST stay
/// documented so `README.md` / `SETUP.md` cannot silently drift out of the real
/// shipped behavior. This test reads the committed docs and asserts the required
/// strings are present. It depends on no device, inbox, or network.
void main() {
  final readme = File('README.md').readAsStringSync();
  final setup = File('SETUP.md').readAsStringSync();
  final readmeLower = readme.toLowerCase();
  final setupLower = setup.toLowerCase();

  group('SETUP.md documents the SMS permission & privacy floor', () {
    test('names the READ_SMS runtime permission', () {
      expect(setup, contains('READ_SMS'));
    });

    test('documents the on-demand / on-device scan flow', () {
      expect(setupLower, contains('scan'));
      expect(setupLower, contains('on-device'));
    });

    test('documents the redaction floor (redacted body + salted hash)', () {
      expect(setupLower, contains('redact'));
      expect(setup, contains('raw_body_redacted'));
      expect(setup, contains('body_hash'));
    });

    test('documents backup hardening (allowBackup + data-extraction rules)', () {
      expect(setup, contains('allowBackup'));
      expect(setupLower, contains('data extraction'));
    });

    test('is honest about at-rest storage (plaintext sandbox, SQLCipher deferred)', () {
      expect(setup, contains('SQLCipher'));
    });

    test('flags sideload-only / Play-Store-ineligible status', () {
      expect(setupLower, contains('sideload'));
      expect(setup, contains('Play Store'));
    });
  });

  group('README.md describes the forecast + SMS privacy model', () {
    test('describes the salary-anchored dated cash-flow forecast', () {
      expect(readmeLower, contains('salary'));
      expect(readmeLower, contains('minimum'));
    });

    test('states Android-only SMS with iOS Gmail-only fallback', () {
      expect(readme, contains('READ_SMS'));
      expect(readmeLower, contains('android-only'));
      expect(readmeLower, contains('gmail'));
    });

    test('states SMS never leaves the device', () {
      expect(readme, contains('never leaves the device'));
    });

    test('notes the Gmail pre-AI prefilter hardening', () {
      expect(readmeLower, contains('prefilter'));
    });
  });
}
