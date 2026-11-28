import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' show join;

class Request {
  late final Dio dio;
  late final Dio _clashDio;

  /// Refuses an untrusted certificate even with the certificate check turned
  /// off, because what it fetches is installed, on Windows as administrator.
  @visibleForTesting
  late final Dio releaseDio;
  String? userAgent;

  ProviderReader? _read;

  void attach(ProviderReader read) {
    _read = read;
  }

  Request({HttpClientAdapter? downloadAdapter}) {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return _findProxy(uri);
        };
        return client;
      },
    );
    if (downloadAdapter != null) {
      _clashDio.httpClientAdapter = downloadAdapter;
    }
    releaseDio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    releaseDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()
          ..badCertificateCallback = ((_, _, _) => false)
          ..findProxy = _findProxy;
      },
    );
  }

  String _findProxy(Uri uri) {
    final read = _read;
    if (read == null) {
      return 'DIRECT';
    }
    return FlClashHttpOverrides.findProxyForReader(read, uri);
  }

  Future<Response<T>> _download<T>(String url, ResponseType responseType) {
    final target = downloadTarget(url);
    final cancelToken = CancelToken();
    return _clashDio
        .getUri<T>(
          target.uri,
          options: Options(responseType: responseType, headers: target.headers),
          cancelToken: cancelToken,
        )
        .timeout(
          downloadTimeoutDuration,
          onTimeout: () {
            cancelToken.cancel();
            throw DioException.receiveTimeout(
              timeout: downloadTimeoutDuration,
              requestOptions: RequestOptions(path: url),
            );
          },
        );
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      return await _download<Uint8List>(url, ResponseType.bytes);
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Stream subscription bytes to disk, keeping the same proxy, auth and
  /// whole-download deadline as the buffered request.
  Future<Headers> downloadSubscription(String url, File file) async {
    final target = downloadTarget(url);
    final cancelToken = CancelToken();
    final timer = Timer(downloadTimeoutDuration, () => cancelToken.cancel());
    try {
      await file.parent.create(recursive: true);
      final response = await _clashDio.downloadUri(
        target.uri,
        file.path,
        options: Options(headers: target.headers),
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled) {
        throw DioException.receiveTimeout(
          timeout: downloadTimeoutDuration,
          requestOptions: RequestOptions(path: url),
        );
      }
      return response.headers;
    } on DioException catch (error) {
      if (cancelToken.isCancelled) {
        throw DioException.receiveTimeout(
          timeout: downloadTimeoutDuration,
          requestOptions: error.requestOptions,
        );
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    try {
      return await _download<String>(url, ResponseType.plain);
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Null when this build is current; throws when GitHub cannot be asked.
  Future<Map<String, dynamic>?> checkForUpdate([
    UpdateChannel channel = UpdateChannel.stable,
  ]) async {
    try {
      final release = await latestRelease(channel);
      final remoteVersion = release['tag_name'] as String;
      final version = globalState.packageInfo.version;
      final hasUpdate = isNewerReleaseForChannel(
        remoteVersion,
        installedVersion: version,
        installedPreviewTag: previewTag,
        channel: channel,
      );
      return hasUpdate ? release : null;
    } catch (error) {
      throw ReleaseUpdateStageException(ReleaseUpdateStage.metadata, error);
    }
  }

  /// The release page redirect still answers once the hourly API quota is spent.
  Future<Map<String, dynamic>> latestRelease([
    UpdateChannel channel = UpdateChannel.stable,
  ]) async {
    if (channel == UpdateChannel.pre) {
      final stable = await _latestStableRelease();
      try {
        final preview = await latestPreviewRelease(selfUpdateSuffix);
        final stableTag = stable['tag_name'] as String;
        final previewTag = preview['tag_name'] as String;
        return compareReleaseTags(stableTag, previewTag) >= 0
            ? stable
            : preview;
      } on FormatException {
        return stable;
      }
    }
    return _latestStableRelease();
  }

  Future<Map<String, dynamic>> _latestStableRelease() async {
    try {
      final response = await releaseDio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      final release = response.data!;
      final suffix = selfUpdateSuffix;
      if (suffix == null) {
        return release;
      }
      final tag = release['tag_name'] as String;
      final assetAvailable =
          await _hasVerifiedReleaseAsset(tag, suffix) ?? false;
      return {...release, 'asset_available': assetAvailable};
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != 403 && status != 429) rethrow;
      commonPrint.log(
        'latest release API failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
    final response = await releaseDio.get<void>(
      'https://github.com/$repository/releases/latest',
      options: Options(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    final location = response.headers.value(HttpHeaders.locationHeader);
    final segments = Uri.tryParse(location ?? '')?.pathSegments ?? const [];
    final tagIndex = segments.indexOf('tag') + 1;
    if (tagIndex == 0 || tagIndex >= segments.length) {
      throw FormatException('No release tag in the redirect', location);
    }
    final tag = segments[tagIndex];
    final suffix = selfUpdateSuffix;
    if (suffix == null) {
      return {'tag_name': tag};
    }
    return {
      'tag_name': tag,
      'asset_available': await _hasVerifiedReleaseAsset(tag, suffix),
    };
  }

  static const _previewReleasePageSize = 30;
  static const _previewReleasePageLimit = 3;

  @visibleForTesting
  Future<Map<String, dynamic>> latestPreviewRelease(
    String? platformSuffix,
  ) async {
    Map<String, dynamic>? latest;
    try {
      for (var page = 1; page <= _previewReleasePageLimit; page++) {
        final response = await releaseDio.get<List<dynamic>>(
          'https://api.github.com/repos/$repository/releases',
          queryParameters: {'per_page': _previewReleasePageSize, 'page': page},
          options: Options(responseType: ResponseType.json),
        );
        final releases = response.data ?? const [];
        for (final release in releases.whereType<Map<String, dynamic>>()) {
          final tag = release['tag_name'];
          final assets = release['assets'];
          if (release['draft'] == true ||
              tag is! String ||
              !isPreviewReleaseTag(tag) ||
              assets is! List ||
              !_containsReleaseAsset(assets, releaseChecksumsName)) {
            continue;
          }
          if (latest == null ||
              isNewerPreviewTag(tag, latest['tag_name'] as String)) {
            final candidate = platformSuffix == null
                ? release
                : await _releaseWithAssetAvailability(release, platformSuffix);
            if (candidate != null) {
              latest = candidate;
            }
          }
        }
        if (releases.length < _previewReleasePageSize) {
          break;
        }
      }
      if (latest != null) {
        return latest;
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != 403 && status != 429) rethrow;
      commonPrint.log(
        'preview release API denied: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      if (latest != null) {
        return latest;
      }
    }

    // GitHub's Atom feed is a lightweight fallback when the REST API is
    // rate-limited. Treat it only as a candidate index: verify each tag's
    // checksum manifest (and the platform asset when applicable), because the
    // feed can also contain tag-only entries.
    try {
      final atomRelease = await _latestPreviewReleaseFromAtom(platformSuffix);
      if (atomRelease != null) {
        return atomRelease;
      }
    } on DioException catch (error) {
      commonPrint.log(
        'preview release Atom fallback failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }

    // GitHub's public release page does not consume the REST API quota.
    // Unlike /releases/latest, it includes prereleases.
    final page = await releaseDio.get<String>(
      'https://github.com/$repository/releases',
      options: Options(responseType: ResponseType.plain),
    );
    final pattern = RegExp('href="/$repository/releases/tag/([^"]+)"');
    final tags =
        pattern
            .allMatches(page.data ?? '')
            .map((match) => match[1]!)
            .where(isPreviewReleaseTag)
            .toSet()
            .toList()
          ..sort((a, b) => a == b ? 0 : (isNewerPreviewTag(a, b) ? -1 : 1));
    for (final tag in tags) {
      if (platformSuffix == null) {
        return {'tag_name': tag};
      }
      final name = releaseAssetName(tag, platformSuffix);
      try {
        final sums = await releaseDio.getUri<String>(
          releaseAssetUri(tag, releaseChecksumsName),
          options: Options(responseType: ResponseType.plain),
        );
        if (releaseChecksum(sums.data ?? '', name) == null) {
          continue;
        }
        final assetAvailable = await _hasReleaseAsset(tag, name);
        return {'tag_name': tag, 'asset_available': assetAvailable};
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
      }
    }
    throw const FormatException('No published preview for this platform');
  }

  Future<Map<String, dynamic>?> _latestPreviewReleaseFromAtom(
    String? platformSuffix,
  ) async {
    final response = await releaseDio.get<String>(
      'https://github.com/$repository/releases.atom',
      options: Options(responseType: ResponseType.plain),
    );
    final pattern = RegExp(r'<id>\s*[^<]*?/releases/tag/([^<\s]+)\s*</id>');
    final tags =
        pattern
            .allMatches(response.data ?? '')
            .map((match) => match[1]!)
            .where(isPreviewReleaseTag)
            .toSet()
            .toList()
          ..sort((a, b) => a == b ? 0 : (isNewerPreviewTag(a, b) ? -1 : 1));

    for (final tag in tags) {
      if (platformSuffix != null) {
        final candidate = await _releaseWithAssetAvailability({
          'tag_name': tag,
        }, platformSuffix);
        if (candidate != null) {
          return candidate;
        }
      } else if (await _hasReleaseChecksums(tag)) {
        return {'tag_name': tag};
      }
    }
    return null;
  }

  Future<bool> _hasReleaseChecksums(String tag) async {
    try {
      final sums = await releaseDio.getUri<String>(
        releaseAssetUri(tag, releaseChecksumsName),
        options: Options(responseType: ResponseType.plain),
      );
      return (sums.data ?? '').trim().isNotEmpty;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return false;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _releaseWithAssetAvailability(
    Map<String, dynamic> release,
    String platformSuffix,
  ) async {
    final tag = release['tag_name'];
    if (tag is! String) {
      return null;
    }
    final assetAvailable = await _hasVerifiedReleaseAsset(tag, platformSuffix);
    if (assetAvailable == null) {
      return null;
    }
    return {...release, 'asset_available': assetAvailable};
  }

  bool _containsReleaseAsset(List<dynamic> assets, String name) {
    return assets.any((asset) => asset is Map && asset['name'] == name);
  }

  Future<bool?> _hasVerifiedReleaseAsset(
    String tag,
    String platformSuffix,
  ) async {
    final name = releaseAssetName(tag, platformSuffix);
    try {
      final sums = await releaseDio.getUri<String>(
        releaseAssetUri(tag, releaseChecksumsName),
        options: Options(responseType: ResponseType.plain),
      );
      if (releaseChecksum(sums.data ?? '', name) == null) {
        return null;
      }
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
    return _hasReleaseAsset(tag, name);
  }

  Future<bool> _hasReleaseAsset(String tag, String name) async {
    try {
      await releaseDio.headUri<void>(
        releaseAssetUri(tag, name),
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return false;
      }
      rethrow;
    }
  }

  Future<String> downloadVerifiedRelease({
    required String tag,
    required String name,
    required String directory,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final Response<String> sums;
    try {
      sums = await releaseDio.getUri<String>(
        releaseAssetUri(tag, releaseChecksumsName),
        options: Options(responseType: ResponseType.plain),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ReleaseUpdateStageException(ReleaseUpdateStage.checksum, error);
    } catch (error) {
      throw ReleaseUpdateStageException(ReleaseUpdateStage.checksum, error);
    }
    final expected = releaseChecksum(sums.data ?? '', name);
    if (expected == null) {
      throw ReleaseNotVerifiedException(name);
    }
    final path = join(directory, name);
    final uri = releaseAssetUri(tag, name);
    try {
      if (app case final android?) {
        await android.downloadFile(
          uri,
          path,
          title: name,
          onReceiveProgress: onReceiveProgress ?? (_, _) {},
          cancelToken: cancelToken ?? CancelToken(),
        );
      } else {
        await releaseDio.downloadUri(
          uri,
          path,
          onReceiveProgress: onReceiveProgress,
          cancelToken: cancelToken,
        );
      }
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ReleaseUpdateStageException(ReleaseUpdateStage.package, error);
    } catch (error) {
      throw ReleaseUpdateStageException(ReleaseUpdateStage.package, error);
    }
    if (await fileSha256(path) != expected) {
      throw ReleaseNotVerifiedException(name);
    }
    return path;
  }
}

final request = Request();

/// Some subscription servers send a gzip or zlib body without saying so in
/// Content-Encoding, which is the only signal dart:io decompresses on.
Codec<List<int>, List<int>>? _unlabeledCodec(Uint8List bytes) {
  return switch (bytes) {
    [0x1f, 0x8b, ...] => gzip,
    [0x78, final flags, ...] when (0x78 << 8 | flags) % 31 == 0 => zlib,
    _ => null,
  };
}

Uint8List decompressUnlabeled(Uint8List bytes) {
  final codec = _unlabeledCodec(bytes);
  if (codec == null) {
    return bytes;
  }
  try {
    return Uint8List.fromList(codec.decode(bytes));
  } on FormatException {
    return bytes;
  }
}

/// Inflate a downloaded profile directly into its temporary file. Feeding
/// bounded chunks avoids materializing another full uncompressed byte array.
Future<void> writeUnlabeledBody(File file, Uint8List bytes) async {
  final codec = _unlabeledCodec(bytes);
  if (codec == null) {
    await file.safeWriteAsBytes(bytes);
    return;
  }
  await file.parent.create(recursive: true);
  try {
    final output = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in codec.decoder.bind(
        Stream.fromIterable(_compressedChunks(bytes)),
      )) {
        await output.writeFrom(chunk);
      }
    } finally {
      await output.close();
    }
  } on FormatException {
    // Preserve the existing behavior for a plain or malformed body that
    // happens to start with compression magic. Validation still decides.
    await file.writeAsBytes(bytes);
  }
}

Iterable<List<int>> _compressedChunks(Uint8List bytes) sync* {
  const chunkSize = 64 * 1024;
  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = offset + chunkSize;
    yield Uint8List.sublistView(
      bytes,
      offset,
      end < bytes.length ? end : bytes.length,
    );
  }
}

/// Return the original download for plain or malformed bodies, otherwise
/// inflate into a separate temporary file without reading the whole input.
Future<File> inflateUnlabeledFile(File source, File output) async {
  final input = await source.open();
  final Uint8List head;
  try {
    head = await input.read(2);
  } finally {
    await input.close();
  }
  final codec = _unlabeledCodec(head);
  if (codec == null) return source;
  try {
    final sink = await output.open(mode: FileMode.write);
    try {
      await for (final chunk in codec.decoder.bind(source.openRead())) {
        await sink.writeFrom(chunk);
      }
    } finally {
      await sink.close();
    }
    return output;
  } on FormatException {
    return source;
  }
}

/// dart:io turns [Uri.userInfo] into Basic credentials still percent-encoded.
@visibleForTesting
({Uri uri, Map<String, Object> headers}) downloadTarget(String url) {
  final uri = url.webUri ?? Uri.parse(url);
  if (uri.userInfo.isEmpty) {
    return (uri: uri, headers: const {});
  }
  final credentials = uri.userInfo.split(':').map(_decodeUserInfo).join(':');
  return (
    uri: uri.replace(userInfo: ''),
    headers: {
      HttpHeaders.authorizationHeader:
          'Basic ${base64.encode(utf8.encode(credentials))}',
    },
  );
}

String _decodeUserInfo(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  final parseValue = HeaderValue.parse(disposition);
  final parameters = parseValue.parameters;
  final fileNamePointKey = parameters.keys.firstWhere(
    (key) => key == 'filename*',
    orElse: () => '',
  );
  if (fileNamePointKey.isNotEmpty) {
    final res = parameters[fileNamePointKey]?.split("''") ?? [];
    if (res.length >= 2) {
      return Uri.decodeComponent(res[1]);
    }
  }
  final fileNameKey = parameters.keys.firstWhere(
    (key) => key == 'filename',
    orElse: () => '',
  );
  if (fileNameKey.isEmpty) return null;
  return parameters[fileNameKey];
}
