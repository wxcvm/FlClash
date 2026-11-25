import 'dart:async';
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

    test('stale validated update cannot overwrite existing bytes', () async {
      final profile = Profile.normal(label: 'stale');
      final savedFile = await profile.file;
      await savedFile.writeAsString('proxies: []');
      var current = true;

      await expectLater(
        profile.saveFile(
          Uint8List.fromList(utf8.encode('proxies: [stale]')),
          validate: (_, _) async {
            current = false; // Simulate an edit during asynchronous validation.
            return null;
          },
          canCommit: () => current,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await savedFile.readAsString(), 'proxies: []');
    });

    test('stale update does not recreate a deleted profile file', () async {
      final profile = Profile.normal(label: 'deleted');
      final savedFile = await profile.file;
      await savedFile.writeAsString('proxies: []');

      await expectLater(
        profile.saveFile(
          Uint8List.fromList(utf8.encode('proxies: [stale]')),
          validate: (_, _) async {
            await savedFile.delete();
            return null;
          },
          canCommit: () => false,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await savedFile.exists(), isFalse);
    });

    test('a newer save wins over an older guarded validation', () async {
      final profile = Profile.normal(label: 'concurrent');
      final validating = Completer<void>();
      final resume = Completer<void>();
      final older = profile.saveFile(
        Uint8List.fromList(utf8.encode('proxies: [old]')),
        validate: (_, _) async {
          validating.complete();
          await resume.future;
          return null;
        },
      );
      final rejected = expectLater(older, throwsA(isA<StateError>()));
      await validating.future;
      try {
        await profile.saveFile(
          Uint8List.fromList(utf8.encode('proxies: [new]')),
          validate: (_, _) async => null,
        );
      } finally {
        resume.complete();
      }
      await rejected;
      expect(await (await profile.file).readAsString(), 'proxies: [new]');
    });

    test('a later save atomically replaces an existing profile file', () async {
      final profile = Profile.normal(label: 'replace');
      await profile.saveFile(
        Uint8List.fromList(utf8.encode('proxies: [old]')),
        validate: (_, _) async => null,
      );

      await profile.saveFile(
        Uint8List.fromList(utf8.encode('proxies: [new]')),
        validate: (_, _) async => null,
      );

      expect(await (await profile.file).readAsString(), 'proxies: [new]');
    });

    test('deletion invalidates a pending save without recreating the file', () async {
      final profile = Profile.normal(label: 'deleted-pending');
      final savedFile = await profile.file;
      await savedFile.writeAsString('proxies: []');
      final validating = Completer<void>();
      final resume = Completer<void>();
      final pending = profile.saveFile(
        Uint8List.fromList(utf8.encode('proxies: [stale]')),
        validate: (_, _) async {
          validating.complete();
          await resume.future;
          return null;
        },
      );
      final rejected = expectLater(pending, throwsA(isA<StateError>()));
      await validating.future;
      ProfileWriteGuard.markDeleted(profile.id);
      await savedFile.delete();
      resume.complete();
      await rejected;
      expect(await savedFile.exists(), isFalse);
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
