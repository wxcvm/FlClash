import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

class _StalledHttpClient extends Fake implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri url)? findProxy;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Completer<HttpClientRequest>().future;
}

class _HostAdapter implements HttpClientAdapter {
  _HostAdapter(this.byHost);

  final Map<String, ResponseBody Function()> byHost;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return byHost[options.uri.host]!();
  }

  @override
  void close({bool force = false}) {}
}

class _PathAdapter implements HttpClientAdapter {
  _PathAdapter(this.byPath);

  final Map<String, ResponseBody Function()> byPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = options.uri.queryParameters['page'];
    final key = page == null
        ? options.uri.path
        : '${options.uri.path}?page=$page';
    return (byPath[key] ?? byPath[options.uri.path])!();
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getTextResponseForUrl propagates the typed DioException', () async {
    // flutter_test's mocked HttpClient answers every request with HTTP 400,
    // which Dio surfaces as a badResponse DioException.
    await expectLater(
      request.getTextResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('getFileResponseForUrl propagates the typed DioException', () async {
    await expectLater(
      request.getFileResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  group('latestRelease', () {
    Request requestAnswering(Map<String, ResponseBody Function()> byHost) {
      return Request()..releaseDio.httpClientAdapter = _HostAdapter(byHost);
    }

    test('reads the release from the API', () async {
      final request = requestAnswering({
        'api.github.com': () => ResponseBody.fromString(
          '{"tag_name":"v1.2.3","body":"notes"}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });

      expect(await request.latestRelease(), {
        'tag_name': 'v1.2.3',
        'body': 'notes',
      });
    });

    test(
      'falls back to the release page when the API is rate limited',
      () async {
        final request = requestAnswering({
          'api.github.com': () => ResponseBody.fromString('{}', 403),
          'github.com': () => ResponseBody.fromString(
            '',
            302,
            headers: {
              HttpHeaders.locationHeader: [
                'https://github.com/owner/repo/releases/tag/v1.2.4',
              ],
            },
          ),
        });

        expect(await request.latestRelease(), {'tag_name': 'v1.2.4'});
      },
    );

    test('does not fall back after a certificate failure', () async {
      var fallbackCalls = 0;
      final request = requestAnswering({
        'api.github.com': () => throw DioException(
          requestOptions: RequestOptions(path: '/releases/latest'),
          type: DioExceptionType.badCertificate,
        ),
        'github.com': () {
          fallbackCalls++;
          return ResponseBody.fromString('', 302);
        },
      });

      await expectLater(
        request.latestRelease(),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.badCertificate,
          ),
        ),
      );
      expect(fallbackCalls, 0);
    });

    test('fails instead of answering when neither endpoint does', () async {
      final request = requestAnswering({
        'api.github.com': () => ResponseBody.fromString('{}', 403),
        'github.com': () => ResponseBody.fromString('', 503),
      });

      await expectLater(request.latestRelease(), throwsA(isA<DioException>()));
    });
  });

  group('checkForUpdate', () {
    test('marks release metadata failures separately', () async {
      final error = DioException(
        requestOptions: RequestOptions(path: '/releases'),
        type: DioExceptionType.badCertificate,
      );
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/repos/$repository/releases/latest': () => throw error,
          '/repos/$repository/releases': () => throw error,
        });

      await expectLater(
        request.checkForUpdate(),
        throwsA(
          isA<ReleaseUpdateStageException>()
              .having((e) => e.stage, 'stage', ReleaseUpdateStage.metadata)
              .having((e) => e.cause, 'cause', isA<DioException>()),
        ),
      );
    });
  });

  group('latestPreviewRelease', () {
    const suffix = 'windows-amd64-setup.exe';
    const older = 'v0.9.3-preview.9.2';
    const newer = 'v0.9.3-preview.10.1';
    final digest = 'a' * 64;
    final page =
        '<a href="/$repository/releases/tag/$older">old</a>'
        '<a href="/$repository/releases/tag/$newer">new</a>'
        '<a href="/$repository/releases/tag/v1.0.0">stable</a>';

    test('falls back from API 403 to the newest matching preview', () async {
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/repos/$repository/releases': () =>
              ResponseBody.fromString('{}', 403),
          '/$repository/releases': () => ResponseBody.fromString(page, 200),
          '/$repository/releases/download/$newer/SHA256SUMS': () =>
              ResponseBody.fromString(
                '$digest  FlClash-0.9.3-preview.10.1-$suffix',
                200,
              ),
          '/$repository/releases/download/$newer/FlClash-0.9.3-preview.10.1-$suffix':
              () => ResponseBody.fromString('', 302),
        });

      expect(await request.latestPreviewRelease(suffix), {
        'tag_name': newer,
        'asset_available': true,
      });
    });

    test('uses Atom after API rate limiting and verifies release candidates', () async {
      final feed = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><id>tag:github.com,2008:Repository/123/releases/tag/$newer</id></entry>
  <entry><id>tag:github.com,2008:Repository/123/releases/tag/$older</id></entry>
</feed>
''';
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/repos/$repository/releases': () =>
              ResponseBody.fromString('{}', 403),
          '/$repository/releases.atom': () =>
              ResponseBody.fromString(feed, 200),
          '/$repository/releases/download/$newer/SHA256SUMS': () =>
              ResponseBody.fromString('', 404),
          '/$repository/releases/download/$older/SHA256SUMS': () =>
              ResponseBody.fromString(
                '$digest  FlClash-0.9.3-preview.9.2-$suffix',
                200,
              ),
          '/$repository/releases/download/$older/FlClash-0.9.3-preview.9.2-$suffix':
              () => ResponseBody.fromString('', 302),
        });

      expect(await request.latestPreviewRelease(suffix), {
        'tag_name': older,
        'asset_available': true,
      });
    });

    test('paginates when the newest release page has no preview', () async {
      final firstPage = List.generate(
        30,
        (_) => {
          'tag_name': 'v0.9.3',
          'draft': false,
          'assets': [
            {'name': releaseChecksumsName},
          ],
        },
      );
      final secondPage = [
        {
          'tag_name': newer,
          'draft': false,
          'assets': [
            {'name': releaseChecksumsName},
            {'name': 'FlClash-0.9.3-preview.10.1-$suffix'},
          ],
        },
      ];
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/repos/$repository/releases?page=1': () => ResponseBody.fromString(
            jsonEncode(firstPage),
            200,
            headers: {
              'content-type': ['application/json'],
            },
          ),
          '/repos/$repository/releases?page=2': () => ResponseBody.fromString(
            jsonEncode(secondPage),
            200,
            headers: {
              'content-type': ['application/json'],
            },
          ),
          '/$repository/releases/download/$newer/SHA256SUMS': () =>
              ResponseBody.fromString(
                '$digest  FlClash-0.9.3-preview.10.1-$suffix',
                200,
              ),
          '/$repository/releases/download/$newer/FlClash-0.9.3-preview.10.1-$suffix':
              () => ResponseBody.fromString('', 302),
        });

      expect(await request.latestPreviewRelease(suffix), {
        'tag_name': newer,
        'draft': false,
        'assets': [
          {'name': releaseChecksumsName},
          {'name': 'FlClash-0.9.3-preview.10.1-$suffix'},
        ],
        'asset_available': true,
      });
    });

    test(
      'offers the release page when the platform package is missing',
      () async {
        final request = Request()
          ..releaseDio.httpClientAdapter = _PathAdapter({
            '/repos/$repository/releases?page=1': () => ResponseBody.fromString(
              jsonEncode([
                {
                  'tag_name': newer,
                  'draft': false,
                  'assets': [
                    {'name': releaseChecksumsName},
                  ],
                },
              ]),
              200,
              headers: {
                'content-type': ['application/json'],
              },
            ),
            '/$repository/releases/download/$newer/SHA256SUMS': () =>
                ResponseBody.fromString(
                  '$digest  FlClash-0.9.3-preview.10.1-$suffix',
                  200,
                ),
            '/$repository/releases/download/$newer/FlClash-0.9.3-preview.10.1-$suffix':
                () => ResponseBody.fromString('', 404),
          });

        final release = await request.latestPreviewRelease(suffix);
        expect(release['tag_name'], newer);
        expect(release['asset_available'], isFalse);
      },
    );

    test('skips a preview without the platform checksum', () async {
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/repos/$repository/releases': () =>
              ResponseBody.fromString('{}', 429),
          '/$repository/releases': () => ResponseBody.fromString(page, 200),
          '/$repository/releases/download/$newer/SHA256SUMS': () =>
              ResponseBody.fromString('$digest  other.apk', 200),
          '/$repository/releases/download/$older/SHA256SUMS': () =>
              ResponseBody.fromString(
                '$digest  FlClash-0.9.3-preview.9.2-$suffix',
                200,
              ),
          '/$repository/releases/download/$older/FlClash-0.9.3-preview.9.2-$suffix':
              () => ResponseBody.fromString('', 302),
        });

      expect(await request.latestPreviewRelease(suffix), {
        'tag_name': older,
        'asset_available': true,
      });
    });
  });

  group('downloadVerifiedRelease', () {
    const name = 'FlClash-1.2.3-android-arm64-v8a.apk';
    final package = utf8.encode('package');
    final digest = sha256.convert(package).toString();
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('release');
    });

    tearDown(() => directory.delete(recursive: true));

    Request requestServing(String sums, List<int> asset) {
      return Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/$repository/releases/download/v1.2.3/SHA256SUMS': () =>
              ResponseBody.fromString(sums, 200),
          '/$repository/releases/download/v1.2.3/$name': () =>
              ResponseBody.fromBytes(asset, 200),
        });
    }

    Future<String> download(Request request) {
      return request.downloadVerifiedRelease(
        tag: 'v1.2.3',
        name: name,
        directory: directory.path,
      );
    }

    test('keeps a file matching the published digest', () async {
      final request = requestServing('$digest  ./$name\n', package);

      final path = await download(request);

      expect(await File(path).readAsBytes(), package);
    });

    test('marks checksum transport failures separately', () async {
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/$repository/releases/download/v1.2.3/SHA256SUMS': () =>
              throw DioException(
                requestOptions: RequestOptions(path: '/SHA256SUMS'),
                type: DioExceptionType.badCertificate,
              ),
        });

      await expectLater(
        download(request),
        throwsA(
          isA<ReleaseUpdateStageException>()
              .having((e) => e.stage, 'stage', ReleaseUpdateStage.checksum)
              .having((e) => e.cause, 'cause', isA<DioException>()),
        ),
      );
    });

    test('marks package transport failures separately', () async {
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/$repository/releases/download/v1.2.3/SHA256SUMS': () =>
              ResponseBody.fromString('$digest  ./$name\n', 200),
          '/$repository/releases/download/v1.2.3/$name': () =>
              throw DioException(
                requestOptions: RequestOptions(path: '/$name'),
                type: DioExceptionType.badCertificate,
              ),
        });

      await expectLater(
        download(request),
        throwsA(
          isA<ReleaseUpdateStageException>()
              .having((e) => e.stage, 'stage', ReleaseUpdateStage.package)
              .having((e) => e.cause, 'cause', isA<DioException>()),
        ),
      );
    });

    test('does not wrap user-cancelled package downloads', () async {
      final request = Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/$repository/releases/download/v1.2.3/SHA256SUMS': () =>
              ResponseBody.fromString('$digest  ./$name\n', 200),
          '/$repository/releases/download/v1.2.3/$name': () =>
              throw DioException(
                requestOptions: RequestOptions(path: '/$name'),
                type: DioExceptionType.cancel,
              ),
        });

      await expectLater(
        download(request),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    });

    test('refuses a file that does not match', () async {
      final request = requestServing('$digest  ./$name\n', utf8.encode('x'));

      await expectLater(
        download(request),
        throwsA(isA<ReleaseNotVerifiedException>()),
      );
    });

    test('refuses an asset the listing does not name', () async {
      final request = requestServing('$digest  ./other.apk\n', package);

      await expectLater(
        download(request),
        throwsA(isA<ReleaseNotVerifiedException>()),
      );
      expect(directory.listSync(), isEmpty);
    });
  });

  test('subscription download preserves bytes and headers', () async {
    final dir = await Directory.systemTemp.createTemp('subscription');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = gzip.encode(utf8.encode('proxies: []'));
    final request = Request(
      downloadAdapter: _HostAdapter({
        'example.com': () => ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            'subscription-userinfo': ['total=123'],
          },
        ),
      }),
    );
    final file = File('${dir.path}/profile');
    final headers = await request.downloadSubscription(
      'https://example.com/profile',
      file,
    );
    expect(headers.value('subscription-userinfo'), 'total=123');
    expect(await file.readAsBytes(), bytes);
  });

  test('file inflation keeps plain and malformed sources intact', () async {
    final dir = await Directory.systemTemp.createTemp('subscription-inflate');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/source');
    final output = File('${dir.path}/output');
    final yaml = utf8.encode('proxies: []');
    for (final codec in [gzip, zlib]) {
      await source.writeAsBytes(codec.encode(yaml));
      expect(await inflateUnlabeledFile(source, output), same(output));
      expect(await output.readAsBytes(), yaml);
    }
    final malformed = [0x1f, 0x8b, 1, 2, 3];
    for (final bytes in [yaml, malformed, <int>[]]) {
      await source.writeAsBytes(bytes);
      expect(await inflateUnlabeledFile(source, output), same(source));
      expect(await source.readAsBytes(), bytes);
    }
  });

  group('downloadTarget', () {
    test('sends a URL without credentials unchanged', () {
      final target = downloadTarget('https://example.com/a.yaml?x=1');

      expect(target.uri.toString(), 'https://example.com/a.yaml?x=1');
      expect(target.headers, isEmpty);
    });

    test('moves decoded credentials into the Authorization header', () {
      for (final url in [
        'https://me@mail.com:p:w@dav.example.com/dav/a.yaml',
        'https://me%40mail.com:p%3Aw@dav.example.com/dav/a.yaml',
      ]) {
        final target = downloadTarget(url);

        expect(target.uri.toString(), 'https://dav.example.com/dav/a.yaml');
        expect(
          target.headers[HttpHeaders.authorizationHeader],
          'Basic ${base64.encode(utf8.encode('me@mail.com:p:w'))}',
        );
      }
    });
  });

  group('decompressUnlabeled', () {
    final yaml = utf8.encode('proxies: []\n');

    test('inflates a gzip or zlib body that arrived unlabeled', () {
      for (final codec in [gzip, zlib]) {
        final body = Uint8List.fromList(codec.encode(yaml));

        expect(decompressUnlabeled(body), yaml);
      }
    });

    test('leaves a plain body untouched', () {
      final body = Uint8List.fromList(yaml);

      expect(decompressUnlabeled(body), same(body));
    });

    test('keeps a body that only starts like gzip', () {
      final body = Uint8List.fromList([0x1f, 0x8b, 1, 2, 3]);

      expect(decompressUnlabeled(body), same(body));
    });
  });

  testWidgets('a stalled download fails at the shared download deadline', (
    tester,
  ) async {
    late final Future<Response<String>> pending;
    HttpOverrides.runZoned(() {
      pending = Request().getTextResponseForUrl('http://127.0.0.1/stalled');
    }, createHttpClient: (_) => _StalledHttpClient());
    var settled = false;
    final outcome = expectLater(
      pending.whenComplete(() => settled = true),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );

    await tester.pump(downloadTimeoutDuration - const Duration(seconds: 1));
    expect(settled, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await outcome;
  });
}
