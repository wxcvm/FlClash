import 'dart:io';

import 'package:fl_clash/core/desktop/network_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'successful proxy request stays distinct from DNS and TUN routing',
    () async {
      final ports = <int>[];
      final diagnostics = DesktopNetworkDiagnostics(
        localPort: (port) async => ports.add(port),
        proxiedHttps: (port) async {
          ports.add(port);
          return 200;
        },
        systemDns: (_) async => [InternetAddress('198.18.0.8')],
        windowsRoutes: () async =>
            ' 0.0.0.0   0.0.0.0   192.0.2.1   192.0.2.2\n'
            ' 0.0.0.0   128.0.0.0   192.0.2.1   192.0.2.2\n'
            ' 128.0.0.0   128.0.0.0   192.0.2.1   192.0.2.2\n',
      );

      final checks = await diagnostics.run(
        engine: 'Mihomo',
        running: true,
        switching: false,
        systemProxyEnabled: true,
        nativeSystemProxy: false,
        nativeEngine: false,
        proxyPort: 7890,
        tunConfigured: true,
      );
      expect(ports, [7890, 7890]);
      expect(checks.map((check) => check.state).toList(), [
        NetworkCheckState.ok,
        NetworkCheckState.warning,
        NetworkCheckState.ok,
        NetworkCheckState.ok,
        NetworkCheckState.ok,
        NetworkCheckState.warning,
      ]);
      expect(checks[4].summary, contains('疑似 Fake-IP'));
      expect(checks[5].summary, contains('成对 /1 分流存在'));
      expect(checks[5].summary, contains('不能证明'));
    },
  );

  test(
    'failed local listener skips HTTPS but still checks system DNS',
    () async {
      var requestedHttps = false;
      final diagnostics = DesktopNetworkDiagnostics(
        localPort: (_) async =>
            throw const SocketException('connection refused'),
        proxiedHttps: (_) async {
          requestedHttps = true;
          return 200;
        },
        systemDns: (_) async => [InternetAddress('93.184.215.14')],
        windowsRoutes: () async => '',
      );

      final checks = await diagnostics.run(
        engine: 'Xray-core',
        running: true,
        switching: false,
        systemProxyEnabled: true,
        nativeSystemProxy: true,
        nativeEngine: true,
        proxyPort: 17890,
        tunConfigured: false,
      );
      expect(requestedHttps, isFalse);
      expect(checks[2].state, NetworkCheckState.failed);
      expect(checks[3].state, NetworkCheckState.skipped);
      expect(checks[4].state, NetworkCheckState.ok);
    },
  );

  test('TUN-only mode is not falsely reported as HTTP failure', () async {
    final diagnostics = DesktopNetworkDiagnostics(
      localPort: (_) async => fail('No listener should be probed'),
      proxiedHttps: (_) async => fail('No HTTPS request should run'),
      systemDns: (_) async => [InternetAddress('93.184.215.14')],
      windowsRoutes: () async => ' 0.0.0.0  0.0.0.0  192.0.2.1',
    );

    final checks = await diagnostics.run(
      engine: 'sing-box',
      running: true,
      switching: false,
      systemProxyEnabled: true,
      nativeSystemProxy: false,
      nativeEngine: true,
      proxyPort: null,
      tunConfigured: true,
    );
    expect(checks[2].state, NetworkCheckState.skipped);
    expect(checks.last.state, NetworkCheckState.warning);
    expect(checks.last.summary, contains('TUN 已配置'));
  });

  test('DNS failure does not suppress route inspection', () async {
    var routeRead = false;
    final diagnostics = DesktopNetworkDiagnostics(
      systemDns: (_) async => throw const SocketException('dns unavailable'),
      windowsRoutes: () async {
        routeRead = true;
        return '';
      },
    );
    final checks = await diagnostics.run(
      engine: 'Mihomo',
      running: false,
      switching: false,
      systemProxyEnabled: false,
      nativeSystemProxy: false,
      nativeEngine: false,
      proxyPort: null,
      tunConfigured: false,
    );
    expect(checks[3].state, NetworkCheckState.failed);
    expect(routeRead, isTrue);
    expect(checks.last.state, NetworkCheckState.warning);
  });

  test('handoff in progress never reports stale proxy results', () async {
    final diagnostics = DesktopNetworkDiagnostics(
      localPort: (_) async => fail('No probe during handoff'),
      proxiedHttps: (_) async => fail('No probe during handoff'),
      systemDns: (_) async => fail('No probe during handoff'),
      windowsRoutes: () async => fail('No probe during handoff'),
    );
    final checks = await diagnostics.run(
      engine: 'sing-box',
      running: true,
      switching: true,
      systemProxyEnabled: true,
      nativeSystemProxy: true,
      nativeEngine: true,
      proxyPort: 17890,
      tunConfigured: false,
    );
    expect(checks, hasLength(1));
    expect(checks.single.state, NetworkCheckState.warning);
  });
}
