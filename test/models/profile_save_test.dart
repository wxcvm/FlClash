import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('profile_save_test');
    await useAppPaths(tempDir);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Profile.saveFile', () {
    // EditProfileView relies on this throwing rather than silently
    // succeeding, so a caller-level try/catch can surface the failure.
    test('rejects an invalid config without touching the saved file', () async {
      final profile = Profile.normal(label: 'p');
      final bytes = Uint8List.fromList(utf8.encode('bad: ['));

      await expectLater(
        profile.saveFile(bytes, validate: (_, _) async => 'invalid config'),
        throwsA(
          isA<MessageException>().having(
            (e) => e.message,
            'message',
            'invalid config',
          ),
        ),
      );

      final savedFile = await profile.file;
      expect(await savedFile.length(), 0);
    });

    test('copies validated bytes and stamps the update time', () async {
      final profile = Profile.normal(label: 'p');
      final bytes = Uint8List.fromList(utf8.encode('proxies: []'));

      final saved = await profile.saveFile(
        bytes,
        validate: (_, _) async => null,
      );

      expect(saved.lastUpdateDate, isNotNull);
      final savedFile = await profile.file;
      expect(await savedFile.readAsString(), 'proxies: []');
    });

    test('streams gzip and zlib into the validated file', () async {
      final yaml = utf8.encode('proxies: []\n# ${'x' * 300000}');
      for (final codec in [gzip, zlib]) {
        final profile = Profile.normal(label: 'compressed');
        String? temporary;
        await profile.saveFile(
          Uint8List.fromList(codec.encode(yaml)),
          decompress: true,
          validate: (path, _) async {
            temporary = path;
            expect(await File(path).readAsBytes(), yaml);
            return null;
          },
        );
        expect(await (await profile.file).readAsBytes(), yaml);
        expect(await File(temporary!).exists(), isFalse);
      }
    });

    test('rejects compressed updates and cleans temporary files', () async {
      final profile = Profile.normal(label: 'p');
      final saved = await profile.file;
      await saved.writeAsString('proxies: []');
      String? temporary;
      await expectLater(
        profile.saveFile(
          Uint8List.fromList(gzip.encode(utf8.encode('invalid'))),
          decompress: true,
          validate: (path, _) async {
            temporary = path;
            return 'invalid config';
          },
        ),
        throwsA(isA<MessageException>()),
      );
      expect(await saved.readAsString(), 'proxies: []');
      expect(await File(temporary!).exists(), isFalse);
    });

    test('validates with the profile age key', () async {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(ageSecretKey: 'AGE-SECRET-KEY-1A');
      final bytes = Uint8List.fromList(utf8.encode('proxies: []'));
      String? ageSecretKey;

      await profile.saveFile(
        bytes,
        validate: (_, key) async {
          ageSecretKey = key;
          return null;
        },
      );

      expect(ageSecretKey, 'AGE-SECRET-KEY-1A');
    });
  });
}
