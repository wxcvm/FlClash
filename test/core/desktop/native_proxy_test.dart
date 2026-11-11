import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late File file;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('native proxy ');
    file = File(p.join(temp.path, 'config.json'));
  });

  tearDown(() async => temp.delete(recursive: true));

  Future<NativeHttpEndpoint?> resolve(
    NativeCoreKind kind,
    List<Object?> inbounds,
  ) async {
    await file.writeAsString(jsonEncode({'inbounds': inbounds}));
    return detectNativeHttpEndpoint(
      NativeCoreSpec(
        kind: kind,
        executable: kind.executableName,
        configPath: file.path,
      ),
    );
  }

  test('sing-box mixed and HTTP inbounds support system HTTP proxy', () async {
    for (final type in ['mixed', 'http']) {
      final endpoint = await resolve(NativeCoreKind.singBox, [
        {'type': type, 'listen': '127.0.0.1', 'listen_port': 7890},
      ]);
      expect(endpoint?.port, 7890);
    }
  });

  test('Xray HTTP inbound supports system HTTP proxy', () async {
    final endpoint = await resolve(NativeCoreKind.xray, [
      {'protocol': 'http', 'listen': '127.0.0.1', 'port': 10809},
    ]);
    expect(endpoint?.port, 10809);
  });

  test(
    'does not treat SOCKS, wildcard or authenticated listeners as HTTP',
    () async {
      expect(
        await resolve(NativeCoreKind.singBox, [
          {'type': 'socks', 'listen': '127.0.0.1', 'listen_port': 7890},
        ]),
        isNull,
      );
      expect(
        await resolve(NativeCoreKind.singBox, [
          {'type': 'mixed', 'listen': '0.0.0.0', 'listen_port': 7890},
        ]),
        isNull,
      );
      expect(
        await resolve(NativeCoreKind.singBox, [
          {
            'type': 'http',
            'listen': '127.0.0.1',
            'listen_port': 7890,
            'users': [
              {'username': 'user', 'password': 'secret'},
            ],
          },
        ]),
        isNull,
      );
      expect(
        await resolve(NativeCoreKind.xray, [
          {
            'protocol': 'http',
            'listen': '127.0.0.1',
            'port': 10809,
            'settings': {
              'accounts': [
                {'user': 'u', 'pass': 'p'},
              ],
            },
          },
        ]),
        isNull,
      );
    },
  );

  test('ambiguous and invalid listener ports are not auto-selected', () async {
    expect(
      await resolve(NativeCoreKind.singBox, [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 7890},
        {'type': 'http', 'listen': '127.0.0.1', 'listen_port': 7891},
      ]),
      isNull,
    );
    for (final port in [-1, 0, 65536, '7890']) {
      expect(
        await resolve(NativeCoreKind.xray, [
          {'protocol': 'http', 'listen': '127.0.0.1', 'port': port},
        ]),
        isNull,
      );
    }
  });

  test(
    'sing-box auto-route TUN is detected independently of HTTP inbounds',
    () async {
      await file.writeAsString(
        jsonEncode({
          'inbounds': [
            {
              'type': 'tun',
              'interface_name': 'sing-tun',
              'address': ['172.18.0.1/30'],
              'auto_route': true,
              'dns_mode': 'native',
            },
          ],
        }),
      );
      final spec = NativeCoreSpec(
        kind: NativeCoreKind.singBox,
        executable: 'sing-box',
        configPath: file.path,
      );
      final tun = await detectNativeTunConfiguration(spec);
      expect(tun?.interfaceName, 'sing-tun');
      expect(tun?.dnsMode, 'native');
      expect(await detectNativeHttpEndpoint(spec), isNull);
      expect(
        await detectNativeTunConfiguration(
          NativeCoreSpec(
            kind: NativeCoreKind.xray,
            executable: 'xray',
            configPath: file.path,
          ),
        ),
        isNull,
      );
    },
  );

  test('TUN without auto_route does not claim system routing', () async {
    await file.writeAsString(
      jsonEncode({
        'inbounds': [
          {'type': 'tun', 'auto_route': false},
        ],
      }),
    );
    expect(
      await detectNativeTunConfiguration(
        NativeCoreSpec(
          kind: NativeCoreKind.singBox,
          executable: 'sing-box',
          configPath: file.path,
        ),
      ),
      isNull,
    );
  });

  test('multiple auto-route TUN inbounds are not silently selected', () async {
    await file.writeAsString(
      jsonEncode({
        'inbounds': [
          {'type': 'tun', 'auto_route': true},
          {'type': 'tun', 'auto_route': true},
        ],
      }),
    );
    expect(
      await detectNativeTunConfiguration(
        NativeCoreSpec(
          kind: NativeCoreKind.singBox,
          executable: 'sing-box',
          configPath: file.path,
        ),
      ),
      isNull,
    );
  });

  test('invalid JSON has no detected HTTP inbound', () async {
    await file.writeAsString('not json');
    expect(
      await detectNativeHttpEndpoint(
        NativeCoreSpec(
          kind: NativeCoreKind.singBox,
          executable: 'sing-box',
          configPath: file.path,
        ),
      ),
      isNull,
    );
  });

  test('readiness check connects to an actual loopback listener', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    expect(
      await waitForNativeHttpEndpoint(
        NativeHttpEndpoint(server.port),
        timeout: const Duration(seconds: 1),
      ),
      isTrue,
    );
  });
}
