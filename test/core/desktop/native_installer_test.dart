import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('official Windows release assets are matched by core and architecture', () {
    expect(
      nativeWindowsAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.windowsX64),
      'sing-box-1.14.4-windows-amd64.zip',
    );
    expect(
      nativeWindowsAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.windowsArm64),
      'sing-box-1.14.4-windows-arm64.zip',
    );
    expect(
      nativeWindowsAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.windowsX64),
      'Xray-windows-64.zip',
    );
    expect(
      nativeWindowsAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.windowsArm64),
      'Xray-windows-arm64-v8a.zip',
    );
    expect(
      nativeWindowsAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.linuxX64),
      isNull,
    );
    expect(
      nativeWindowsAssetName(NativeCoreKind.singBox, '../wrong', Abi.windowsX64),
      isNull,
    );
  });

  test('missing digest or mismatched asset is never installed', () {
    expect(
      () => NativeCoreRelease.fromMetadata(
        NativeCoreKind.singBox,
        {
          'tag_name': 'v1.14.4',
          'assets': [
            {
              'name': 'sing-box-1.14.4-windows-amd64.zip',
              'size': 123,
              'digest': null,
            },
          ],
        },
        Abi.windowsX64,
      ),
      throwsFormatException,
    );
    expect(
      () => NativeCoreRelease.fromMetadata(
        NativeCoreKind.xray,
        {'tag_name': '../oops', 'assets': []},
        Abi.windowsX64,
      ),
      throwsFormatException,
    );
  });

  late Directory root;
  late List<int> zip;
  late Map<String, dynamic> metadata;
  var downloads = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native install ');
    final archive = Archive();
    archive.addFile(
      ArchiveFile(
        'sing-box-1.14.4-windows-amd64/sing-box.exe',
        4,
        [77, 90, 1, 2],
      ),
    );
    zip = ZipEncoder().encode(archive);
    metadata = {
      'tag_name': 'v1.14.4',
      'assets': [
        {
          'name': 'sing-box-1.14.4-windows-amd64.zip',
          'size': zip.length,
          'digest': 'sha256:${sha256.convert(zip)}',
        },
      ],
    };
    downloads = 0;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  NativeCoreInstaller installer() => NativeCoreInstaller(
    supportRoot: root.path,
    abi: Abi.windowsX64,
    fetchRelease: (_) async => metadata,
    fetchArchive: (_, file) async {
      downloads++;
      await file.writeAsBytes(zip);
    },
  );

  test('downloads, verifies and selects sing-box across app restarts', () async {
    final first = installer();
    final installed = await first.installLatest(NativeCoreKind.singBox);

    expect(installed.tag, 'v1.14.4');
    expect(installed.alreadyInstalled, isFalse);
    expect(await File(installed.executable).readAsBytes(), [77, 90, 1, 2]);
    expect(downloads, 1);

    final afterRestart = installer();
    expect(
      await afterRestart.installedExecutable(NativeCoreKind.singBox),
      installed.executable,
    );
    final second = await afterRestart.installLatest(NativeCoreKind.singBox);
    expect(second.alreadyInstalled, isTrue);
    expect(second.executable, installed.executable);
    expect(downloads, 1);
  });

  test('rejects corrupted downloads without selecting an executable', () async {
    metadata['assets'][0]['digest'] = 'sha256:${'0' * 64}';
    final manager = installer();

    await expectLater(
      manager.installLatest(NativeCoreKind.singBox),
      throwsFormatException,
    );
    expect(await manager.installedExecutable(NativeCoreKind.singBox), isNull);
    final coreDir = Directory(p.join(root.path, 'singBox'));
    expect(
      coreDir.listSync().whereType<Directory>().toList(),
      isEmpty,
    );
  });

  test('Xray installation keeps its geo data beside the executable', () async {
    final archive = Archive();
    archive.addFile(ArchiveFile('xray.exe', 2, [77, 90]));
    archive.addFile(ArchiveFile('geoip.dat', 2, [1, 2]));
    archive.addFile(ArchiveFile('geosite.dat', 2, [3, 4]));
    archive.addFile(ArchiveFile('unrelated.txt', 2, [5, 6]));
    zip = ZipEncoder().encode(archive);
    metadata = {
      'tag_name': 'v26.11.9',
      'assets': [
        {
          'name': 'Xray-windows-64.zip',
          'size': zip.length,
          'digest': 'sha256:${sha256.convert(zip)}',
        },
      ],
    };

    final installed = await installer().installLatest(NativeCoreKind.xray);
    final dir = File(installed.executable).parent;
    expect(await File(p.join(dir.path, 'geoip.dat')).readAsBytes(), [1, 2]);
    expect(await File(p.join(dir.path, 'geosite.dat')).readAsBytes(), [3, 4]);
    expect(await File(p.join(dir.path, 'unrelated.txt')).exists(), isFalse);
  });
}
