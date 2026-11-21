import 'dart:convert';

import 'package:tuple/tuple.dart';

class BoardProviderPrivate {
  static Tuple3<String, String, String> getBycodeUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String code,
  }) {
    return Tuple3(
      'https://dot.karing.app/provider/bycode',
      '',
      jsonEncode({'app': app, 'version': version, 'did': did, 'code': code}),
    );
  }

  static Tuple3<String, String, String> getNotifyIntegrationUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String url,
    required String type,
  }) {
    return Tuple3(
      'https://dot.karing.app/provider/notify',
      '',
      jsonEncode({
        'app': app, 'version': version, 'did': did, 'url': url, 'type': type,
      }),
    );
  }

  static Tuple3<String, String, String> getNoticePushUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String pid,
  }) {
    return Tuple3(
      'https://dot.karing.app/provider/notice',
      '',
      jsonEncode({'app': app, 'version': version, 'did': did, 'pid': pid}),
    );
  }
}
