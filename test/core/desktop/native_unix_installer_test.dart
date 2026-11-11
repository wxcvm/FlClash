import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('matches official Unix command-line releases', () {
    expect(
      nativeReleaseAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.linuxX64),
      'sing-box-1.14.4-linux-amd64.tar.gz',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.linuxArm64),
      'sing-box-1.14.4-linux-arm64.tar.gz',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.macosX64),
      'sing-box-1.14.4-darwin-amd64.tar.gz',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.singBox, 'v1.14.4', Abi.macosArm64),
      'sing-box-1.14.4-darwin-arm64.tar.gz',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.hysteria2, 'v2.13.0', Abi.linuxX64),
      'hysteria-linux-amd64',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.hysteria2, 'v2.13.0', Abi.macosArm64),
      'hysteria-darwin-arm64',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.linuxX64),
      'Xray-linux-64.zip',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.linuxArm64),
      'Xray-linux-arm64-v8a.zip',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.macosX64),
      'Xray-macos-64.zip',
    );
    expect(
      nativeReleaseAssetName(NativeCoreKind.xray, 'v26.11.9', Abi.macosArm64),
      'Xray-macos-arm64-v8a.zip',
    );
    expect(
      nativeReleaseAssetName(
        NativeCoreKind.singBox,
        'v1.14.4',
        Abi.androidArm64,
      ),
      isNull,
    );
  });

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('unix core install ');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  NativeCoreInstaller installer(
    Abi abi,
    Map<String, dynamic> metadata,
    List<int> compressed,
  ) => NativeCoreInstaller(
    supportRoot: root.path,
    abi: abi,
    fetchRelease: (_) async => metadata,
    fetchArchive: (_, file) async => file.writeAsBytes(compressed),
  );

  test(
    'installs verified sing-box tar.gz and preserves executable mode',
    () async {
      final tar = Archive();
      tar.addFile(
        ArchiveFile('sing-box-1.14.4-linux-amd64/sing-box', 4, [
          127,
          69,
          76,
          70,
        ]),
      );
      final archive = GZipEncoder().encode(TarEncoder().encode(tar));
      final metadata = {
        'tag_name': 'v1.14.4',
        'assets': [
          {
            'name': 'sing-box-1.14.4-linux-amd64.tar.gz',
            'size': archive.length,
            'digest': 'sha256:${sha256.convert(archive)}',
          },
        ],
      };
      final manager = installer(Abi.linuxX64, metadata, archive);
      final result = await manager.installLatest(NativeCoreKind.singBox);

      expect(result.alreadyInstalled, isFalse);
      expect(p.basename(result.executable), 'sing-box');
      expect(await File(result.executable).readAsBytes(), [127, 69, 76, 70]);
      final stat = await File(result.executable).stat();
      expect(stat.mode & 0x40, isNot(0)); // User executable bit.
      expect(
        await NativeCoreInstaller(
          supportRoot: root.path,
          abi: Abi.linuxX64,
        ).installedExecutable(NativeCoreKind.singBox),
        result.executable,
      );
    },
  );

  test(
    'installs raw Hysteria Linux release with executable permission',
    () async {
      final binary = [127, 69, 76, 70, 1, 2, 3];
      final metadata = {
        'tag_name': 'app/v2.13.0',
        'assets': [
          {
            'name': 'hysteria-linux-amd64',
            'size': binary.length,
            'digest': 'sha256:${sha256.convert(binary)}',
          },
        ],
      };
      final manager = installer(Abi.linuxX64, metadata, binary);
      final installed = await manager.installLatest(NativeCoreKind.hysteria2);
      expect(p.basename(installed.executable), 'hysteria');
      expect(await File(installed.executable).readAsBytes(), binary);
      expect((await File(installed.executable).stat()).mode & 0x40, isNot(0));
    },
  );

  test('installs Linux Xray zip without losing geo resources', () async {
    final zip = Archive()
      ..addFile(ArchiveFile('xray', 3, [10, 20, 30]))
      ..addFile(ArchiveFile('geoip.dat', 2, [1, 2]))
      ..addFile(ArchiveFile('geosite.dat', 2, [3, 4]));
    final archive = ZipEncoder().encode(zip);
    final metadata = {
      'tag_name': 'v26.11.9',
      'assets': [
        {
          'name': 'Xray-linux-arm64-v8a.zip',
          'size': archive.length,
          'digest': 'sha256:${sha256.convert(archive)}',
        },
      ],
    };
    final manager = installer(Abi.linuxArm64, metadata, archive);
    final installed = await manager.installLatest(NativeCoreKind.xray);
    final directory = File(installed.executable).parent;
    expect(p.basename(installed.executable), 'xray');
    expect(await File(p.join(directory.path, 'geoip.dat')).readAsBytes(), [
      1,
      2,
    ]);
    expect(await File(p.join(directory.path, 'geosite.dat')).readAsBytes(), [
      3,
      4,
    ]);
    expect((await File(installed.executable).stat()).mode & 0x40, isNot(0));
  });

  test('bad gzip digest does not create a selected Unix core', () async {
    final archive = GZipEncoder().encode(
      TarEncoder().encode(Archive()..addFile(ArchiveFile('sing-box', 1, [1]))),
    );
    final metadata = {
      'tag_name': 'v1.14.4',
      'assets': [
        {
          'name': 'sing-box-1.14.4-linux-amd64.tar.gz',
          'size': archive.length,
          'digest': 'sha256:${'0' * 64}',
        },
      ],
    };
    final manager = installer(Abi.linuxX64, metadata, archive);
    await expectLater(
      manager.installLatest(NativeCoreKind.singBox),
      throwsFormatException,
    );
    expect(await manager.installedExecutable(NativeCoreKind.singBox), isNull);
  });
}
