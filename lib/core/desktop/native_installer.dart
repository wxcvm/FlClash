import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/path.dart';
import 'package:path/path.dart' as p;

import 'native_core.dart';

const _maxArchiveBytes = 100 * 1024 * 1024;
const _maxFileBytes = 160 * 1024 * 1024;
final _safeTag = RegExp(r'^[A-Za-z0-9._-]+$');
final _sha256Digest = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

typedef NativeReleaseFetch = Future<Map<String, dynamic>> Function(Uri url);
typedef NativeArchiveFetch = Future<void> Function(Uri url, File destination);

/// Only official Windows releases are installed here. Other desktops can
/// continue using the manual native executable picker.
String? nativeWindowsAssetName(NativeCoreKind kind, String tag, Abi abi) {
  if (!_safeTag.hasMatch(tag)) return null;
  final architecture = switch (abi) {
    Abi.windowsX64 => 'amd64',
    Abi.windowsArm64 => 'arm64',
    _ => null,
  };
  if (architecture == null) return null;
  if (kind == NativeCoreKind.singBox) {
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    return 'sing-box-$version-windows-$architecture.zip';
  }
  return architecture == 'amd64'
      ? 'Xray-windows-64.zip'
      : 'Xray-windows-arm64-v8a.zip';
}

String _repository(NativeCoreKind kind) => switch (kind) {
  NativeCoreKind.singBox => 'SagerNet/sing-box',
  NativeCoreKind.xray => 'XTLS/Xray-core',
};

final class NativeCoreRelease {
  final NativeCoreKind kind;
  final String tag;
  final Uri downloadUrl;
  final String sha256Hex;
  final int size;

  const NativeCoreRelease({
    required this.kind,
    required this.tag,
    required this.downloadUrl,
    required this.sha256Hex,
    required this.size,
  });

  static NativeCoreRelease fromMetadata(
    NativeCoreKind kind,
    Map<String, dynamic> metadata,
    Abi abi,
  ) {
    final tag = metadata['tag_name'];
    if (tag is! String || !_safeTag.hasMatch(tag)) {
      throw const FormatException('Invalid upstream release version');
    }
    final name = nativeWindowsAssetName(kind, tag, abi);
    if (name == null) {
      throw UnsupportedError(
        'Automatic installation is not available on this platform',
      );
    }
    final assets = metadata['assets'];
    if (assets is! List) {
      throw const FormatException('Upstream release has no assets');
    }
    for (final item in assets) {
      if (item is! Map || item['name'] != name) continue;
      final digest = item['digest'];
      final size = item['size'];
      if (digest is! String ||
          !_sha256Digest.hasMatch(digest) ||
          size is! int ||
          size < 1 ||
          size > _maxArchiveBytes) {
        throw const FormatException('Upstream asset has no valid SHA-256/size');
      }
      // Build from the trusted official repository and the exact asset name,
      // rather than using an arbitrary download URL supplied by API metadata.
      return NativeCoreRelease(
        kind: kind,
        tag: tag,
        downloadUrl: Uri.parse(
          'https://github.com/${_repository(kind)}/releases/download/$tag/$name',
        ),
        sha256Hex: digest.substring('sha256:'.length).toLowerCase(),
        size: size,
      );
    }
    throw FormatException('No official Windows core asset found: $name');
  }
}

final class NativeCoreInstallation {
  final String tag;
  final String executable;
  final bool alreadyInstalled;

  const NativeCoreInstallation({
    required this.tag,
    required this.executable,
    required this.alreadyInstalled,
  });
}

/// Installs release-versioned binaries in writable application support data.
/// Never replaces FlClash's bundled Mihomo executable or an active native core.
final class NativeCoreInstaller {
  final String? supportRoot;
  final NativeReleaseFetch fetchRelease;
  final NativeArchiveFetch fetchArchive;
  final Abi abi;
  bool _installing = false;

  NativeCoreInstaller({
    this.supportRoot,
    NativeReleaseFetch? fetchRelease,
    NativeArchiveFetch? fetchArchive,
    Abi? abi,
  }) : fetchRelease = fetchRelease ?? _fetchOfficialRelease,
       fetchArchive = fetchArchive ?? _downloadArchive,
       abi = abi ?? Abi.current();

  bool get supported =>
      nativeWindowsAssetName(NativeCoreKind.singBox, 'v1.0.0', abi) != null;

  Future<String> get _root async =>
      supportRoot ?? p.join(await appPath.homeDirPath, 'native-cores');

  Future<String?> installedExecutable(NativeCoreKind kind) async {
    final directory = p.join(await _root, kind.name);
    final marker = File(p.join(directory, 'current-version.txt'));
    if (!await marker.exists()) return null;
    final tag = (await marker.readAsString()).trim();
    if (!_safeTag.hasMatch(tag)) return null;
    final executable = File(
      p.join(directory, tag, '${kind.executableName}.exe'),
    );
    return await executable.exists() ? executable.path : null;
  }

  Future<NativeCoreInstallation> installLatest(NativeCoreKind kind) async {
    if (_installing)
      throw StateError('A native core installation is in progress');
    _installing = true;
    try {
      final metadata = await fetchRelease(
        Uri.parse(
          'https://api.github.com/repos/${_repository(kind)}/releases/latest',
        ),
      );
      final release = NativeCoreRelease.fromMetadata(kind, metadata, abi);
      return await install(release);
    } finally {
      _installing = false;
    }
  }

  /// The caller must avoid installing while a native process is active.
  Future<NativeCoreInstallation> install(NativeCoreRelease release) async {
    if (nativeWindowsAssetName(release.kind, release.tag, abi) == null) {
      throw UnsupportedError('Unsupported native core platform');
    }
    final kindDir = Directory(p.join(await _root, release.kind.name));
    await kindDir.create(recursive: true);
    final targetDir = Directory(p.join(kindDir.path, release.tag));
    final filename = '${release.kind.executableName}.exe';
    final executable = File(p.join(targetDir.path, filename));
    final exists = await executable.exists();
    if (!exists) {
      if (await targetDir.exists()) {
        throw StateError('Incomplete core installation: ${targetDir.path}');
      }
      final stage = await kindDir.createTemp('.install-');
      try {
        final zip = File(p.join(stage.path, 'release.zip'));
        await fetchArchive(release.downloadUrl, zip);
        final size = await zip.length();
        if (size != release.size || size > _maxArchiveBytes) {
          throw const FormatException('Downloaded archive size mismatch');
        }
        final digest = await sha256.bind(zip.openRead()).first;
        if (digest.toString().toLowerCase() != release.sha256Hex) {
          throw const FormatException('Downloaded archive SHA-256 mismatch');
        }
        final archive = ZipDecoder().decodeBytes(
          await zip.readAsBytes(),
          verify: true,
        );
        var foundExecutable = false;
        for (final entry in archive) {
          if (!entry.isFile || entry.isSymbolicLink) continue;
          // Ignore archive paths completely: only copy recognized filenames
          // into our flat, fixed installation directory.
          final name = p.posix.basename(entry.name.replaceAll('\\', '/'));
          if (name != filename &&
              !(release.kind == NativeCoreKind.xray &&
                  (name == 'geoip.dat' || name == 'geosite.dat'))) {
            continue;
          }
          if (entry.size > _maxFileBytes) {
            throw const FormatException('Upstream executable is too large');
          }
          if (name == filename && foundExecutable) {
            throw const FormatException('Duplicate executable in archive');
          }
          await File(
            p.join(stage.path, name),
          ).writeAsBytes(entry.readBytes(), flush: true);
          if (name == filename) foundExecutable = true;
        }
        if (!foundExecutable) {
          throw const FormatException('Official core executable is missing');
        }
        await zip.delete();
        await stage.rename(targetDir.path);
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    }
    // Remember the selected version across app restarts without putting any
    // generated file in the application installation directory.
    await File(
      p.join(kindDir.path, 'current-version.txt'),
    ).writeAsString(release.tag, flush: true);
    return NativeCoreInstallation(
      tag: release.tag,
      executable: executable.path,
      alreadyInstalled: exists,
    );
  }
}

Future<Map<String, dynamic>> _fetchOfficialRelease(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(url);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'FlClash-native-core-manager',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub release lookup failed: ${response.statusCode}',
      );
    }
    final json = jsonDecode(await utf8.decoder.bind(response).join());
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid GitHub release response');
    }
    return json;
  } finally {
    client.close(force: true);
  }
}

Future<void> _downloadArchive(Uri url, File destination) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(url);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'FlClash-native-core-manager',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Upstream binary download failed: ${response.statusCode}',
      );
    }
    if (response.contentLength > _maxArchiveBytes) {
      throw const FormatException('Upstream archive exceeds size limit');
    }
    var received = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in response) {
        received += chunk.length;
        if (received > _maxArchiveBytes) {
          throw const FormatException('Upstream archive exceeds size limit');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close(force: true);
  }
}

final nativeCoreInstaller = NativeCoreInstaller();
