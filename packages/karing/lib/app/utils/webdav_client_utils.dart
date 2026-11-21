import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:karing/app/runtime/return_result.dart';

class WebdavClient {
  String url = '';
  String user = '';
  String password = '';
  String? proxyUrl;

  Map<String, String> get headers {
    final auth = base64Encode(utf8.encode('$user:$password'));
    return {'Authorization': 'Basic $auth'};
  }
}

abstract final class WebdavClientUtils {
  static Future<ReturnResult<WebdavClient>> connect(
    String? proxyUrl,
    String url,
    String user,
    String password,
  ) async {
    final client = WebdavClient()
      ..url = url
      ..user = user
      ..password = password
      ..proxyUrl = proxyUrl;
    try {
      final response = await http
          .head(Uri.parse(url), headers: client.headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 200 && response.statusCode < 500) {
        return ReturnResult(data: client);
      }
      return ReturnResult(
        error: ReturnResultError('HTTP ${response.statusCode}'),
      );
    } catch (e) {
      return ReturnResult(error: ReturnResultError(e.toString()));
    }
  }

  static String _join(String url, String relativePath) =>
      url.endsWith('/') ? url + relativePath : '$url/$relativePath';

  static Future<ReturnResult<List<String>>> list(
    WebdavClient client,
  ) async {
    try {
      final request = http.Request('PROPFIND', Uri.parse(client.url));
      request.headers.addAll({
        ...client.headers,
        'Depth': '1',
      });
      final response = await request.send();
      final body = await response.stream.bytesToString();
      if (response.statusCode != 207 && response.statusCode != 200) {
        return ReturnResult(
          error: ReturnResultError('HTTP ${response.statusCode}'),
        );
      }
      final names = <String>[];
      for (final match
          in RegExp('href=([^>]+)').allMatches(body)) {
        names.add(match.group(1)!);
      }
      if (names.isEmpty) {
        for (final match in RegExp('>([^<>]+)</d:href>')
            .allMatches(body)) {
          names.add(match.group(1)!);
        }
      }
      return ReturnResult(data: names);
    } catch (e) {
      return ReturnResult(error: ReturnResultError(e.toString()));
    }
  }

  static Future<ReturnResultError?> upload(
    WebdavClient client, {
    required String relativePath,
    required String localPath,
  }) async {
    try {
      final data = await File(localPath).readAsBytes();
      final response = await http.put(
        Uri.parse(_join(client.url, relativePath)),
        headers: client.headers,
        body: data,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return ReturnResultError('HTTP ${response.statusCode}');
    } catch (e) {
      return ReturnResultError(e.toString());
    }
  }

  static Future<ReturnResultError?> download(
    WebdavClient client, {
    required String relativePath,
    required String localPath,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(_join(client.url, relativePath)),
        headers: client.headers,
      );
      if (response.statusCode != 200) {
        return ReturnResultError('HTTP ${response.statusCode}');
      }
      await File(localPath).writeAsBytes(response.bodyBytes);
      return null;
    } catch (e) {
      return ReturnResultError(e.toString());
    }
  }

  static Future<ReturnResultError?> delete(
    WebdavClient client,
    String filename,
  ) async {
    try {
      final response = await http.delete(
        Uri.parse(_join(client.url, filename)),
        headers: client.headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return ReturnResultError('HTTP ${response.statusCode}');
    } catch (e) {
      return ReturnResultError(e.toString());
    }
  }

  static bool isInnerError(String message) => false;
}
