import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/core/desktop/native_clash_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> controllerConfig(String address, String secret) => {
  'experimental': {
    'clash_api': {'external_controller': address, 'secret': secret},
  },
};

Map<String, dynamic> connection() => {
  'id': 'c1',
  'start': '2026-11-24T10:00:00Z',
  'metadata': {
    'network': 'tcp',
    'sourceIP': '172.19.0.1',
    'processPath': 'browser.exe',
    'host': 'example.test',
  },
  'chains': ['exit', 'selector'],
  'rule': 'final',
  'rulePayload': '',
  'upload': 10,
  'download': 20,
};

void main() {
  test('only explicitly authenticated IPv4 loopback is accepted', () {
    expect(
      NativeClashController.fromConfig(
        controllerConfig('127.0.0.1:9090', 'token'),
      ),
      isNotNull,
    );
    for (final address in [
      '0.0.0.0:9090',
      '192.168.1.2:9090',
      '127.0.0.1:0',
      '127.0.0.1:65536',
      'https://127.0.0.1:9090',
    ]) {
      expect(
        NativeClashController.fromConfig(controllerConfig(address, 'token')),
        isNull,
      );
    }
    expect(
      NativeClashController.fromConfig(
        controllerConfig('127.0.0.1:9090', ''),
      ),
      isNull,
    );
  });

  test('native graph preserves reported exit-first chain and traffic', () {
    final rows = nativeClashConnections({
      'connections': [connection()],
    });
    final route = connectionRoutes(rows).single;
    expect(route.hops, ['selector', 'exit']);
    expect(route.source, 'browser.exe');
    expect(route.traffic, 30);
    expect(
      connectionRoutes(
        nativeClashConnections({
          'connections': [
            {...connection(), 'chains': null},
          ],
        }),
      ).single.hops,
      isEmpty,
    );
    expect(
      () => nativeClashConnections({'connections': 'invalid'}),
      throwsFormatException,
    );
  });

  test('local API sends bearer credentials and reads actual selections', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer test-secret') {
        request.response.statusCode = HttpStatus.unauthorized;
      } else if (request.uri.path == '/connections') {
        request.response.write(jsonEncode({'connections': [connection()]}));
      } else {
        request.response.write(jsonEncode({
          'proxies': {
            'GLOBAL': {'all': ['selector'], 'now': 'selector'},
            'selector': {'all': ['exit'], 'now': 'exit'},
            'exit': {'type': 'VLESS'},
          },
        }));
      }
      await request.response.close();
    });
    final api = NativeClashController.fromConfig(
      controllerConfig('127.0.0.1:${server.port}', 'test-secret'),
    )!;
    expect((await api.connections()).single.id, 'c1');
    expect(await api.selections(), {'selector': 'exit'});
    expect(paths, ['/connections', '/proxies']);
  });
}
