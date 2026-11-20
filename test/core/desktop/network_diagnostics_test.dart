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

  test(
    'diagnostic highlights a TUN route mismatch without changing routes',
    () async {
      const routes =
          '0.0.0.0 0.0.0.0 192.0.2.1 192.0.2.20 20\n'
          '198.18.0.0 255.255.255.252 On-link 198.18.0.1 256\n';
      final checks =
          await DesktopNetworkDiagnostics(
            systemDns: (_) async => [InternetAddress('93.184.215.14')],
            windowsRoutes: () async => routes,
          ).run(
            engine: 'Mihomo',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: false,
            proxyPort: null,
            tunConfigured: true,
          );
      expect(checks.last.summary, contains('198.18.0.8'));
      expect(checks.last.summary, contains('疑似 TUN 路由覆盖丢失'));
    },
  );

  test('stopped Mihomo cannot claim TUN route loss', () async {
    const routes =
        '0.0.0.0 0.0.0.0 192.0.2.1 192.0.2.20 20\n'
        '198.18.0.0 255.255.255.252 On-link 198.18.0.1 256\n';
    final checks =
        await DesktopNetworkDiagnostics(
          systemDns: (_) async => [InternetAddress('93.184.215.14')],
          windowsRoutes: () async => routes,
        ).run(
          engine: 'Mihomo',
          running: false,
          switching: false,
          systemProxyEnabled: false,
          nativeSystemProxy: false,
          nativeEngine: false,
          proxyPort: null,
          tunConfigured: true,
        );
    expect(checks.last.summary, isNot(contains('疑似 TUN 路由覆盖丢失')));
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

  test(
    'AdGuard challenge queries a fresh name and never invents ownership',
    () async {
      final names = <String>[];
      Future<List<NetworkCheck>> check(String answer) =>
          DesktopNetworkDiagnostics(
            systemDns: (host) async {
              names.add(host);
              if (host != 'example.com') {
                throw const SocketException('NXDOMAIN');
              }
              return [InternetAddress(answer)];
            },
            windowsRoutes: () async => '',
          ).run(
            engine: 'Mihomo',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: false,
            proxyPort: null,
            tunConfigured: true,
            followingWindowsDns: true,
          );

      final synthetic = await check('198.18.0.8');
      expect(synthetic[3].title, 'Windows 系统 DNS');
      expect(synthetic[3].state, NetworkCheckState.warning);
      expect(synthetic[4].title, 'AdGuard DNS 查询日志');
      expect(synthetic[4].state, NetworkCheckState.warning);
      expect(synthetic[4].summary, contains('查询日志'));
      expect(synthetic[4].summary, contains(names[1]));

      final real = await check('93.184.215.14');
      expect(real[3].state, NetworkCheckState.ok);
      expect(real[4].state, NetworkCheckState.warning);
      expect(names, hasLength(4));
      expect(names[0], 'example.com');
      expect(names[2], 'example.com');
      expect(names[1], startsWith('flclash-check-'));
      expect(names[1], endsWith('.example.com'));
      expect(names[3], isNot(names[1]));
    },
  );

  test('stopped Mihomo does not generate an AdGuard DNS challenge', () async {
    final names = <String>[];
    final checks =
        await DesktopNetworkDiagnostics(
          systemDns: (host) async {
            names.add(host);
            return [InternetAddress('93.184.215.14')];
          },
          windowsRoutes: () async => '',
        ).run(
          engine: 'Mihomo',
          running: false,
          switching: false,
          systemProxyEnabled: false,
          nativeSystemProxy: false,
          nativeEngine: false,
          proxyPort: null,
          tunConfigured: false,
          followingWindowsDns: true,
        );
    expect(names, ['example.com']);
    expect(checks[4].state, NetworkCheckState.skipped);
  });

  test(
    'Mihomo DNS success is a historical core lookup, not live node DNS',
    () async {
      final checks =
          await DesktopNetworkDiagnostics(
            coreHealth: () async => {
              'state': 'route-unreachable',
              'dns': 'resolved',
              'checked-at': DateTime.utc(2026, 11, 20).millisecondsSinceEpoch,
            },
            systemDns: (_) async => [InternetAddress('93.184.215.14')],
            windowsRoutes: () async => '',
          ).run(
            engine: 'Mihomo',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: false,
            proxyPort: null,
            tunConfigured: false,
          );
      final evidence = checks.singleWhere(
        (check) => check.title == 'Mihomo 内核 DNS 历史证据',
      );
      expect(evidence.state, NetworkCheckState.warning);
      expect(evidence.detail, contains('核心独立 DNS 查询解析成功'));
      expect(evidence.detail, contains('此前一次测试地址'));
      expect(evidence.detail, contains('不证明当前节点入口域名可解析'));
    },
  );

  test(
    'Mihomo DNS failure is not confused with Windows resolver status',
    () async {
      final checks =
          await DesktopNetworkDiagnostics(
            coreHealth: () async => {
              'state': 'dns-failure',
              'dns': 'failed',
              'checked-at': DateTime.utc(2026, 11, 20).millisecondsSinceEpoch,
            },
            systemDns: (_) async => [InternetAddress('93.184.215.14')],
            windowsRoutes: () async => '',
          ).run(
            engine: 'Mihomo',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: false,
            proxyPort: null,
            tunConfigured: false,
          );
      final system = checks.singleWhere((c) => c.title == 'Windows 系统 DNS');
      final core = checks.singleWhere((c) => c.title == 'Mihomo 内核 DNS 历史证据');
      expect(system.state, NetworkCheckState.ok);
      expect(core.state, NetworkCheckState.warning);
      expect(core.detail, contains('核心独立 DNS 查询解析失败'));
    },
  );

  test('untested core DNS snapshot cannot claim successful lookup', () async {
    final checks =
        await DesktopNetworkDiagnostics(
          coreHealth: () async => {'state': 'reachable', 'dns': 'untested'},
          systemDns: (_) async => [InternetAddress('93.184.215.14')],
          windowsRoutes: () async => '',
        ).run(
          engine: 'Mihomo',
          running: true,
          switching: false,
          systemProxyEnabled: false,
          nativeSystemProxy: false,
          nativeEngine: false,
          proxyPort: null,
          tunConfigured: false,
        );
    final core = checks.singleWhere((c) => c.title == 'Mihomo 内核 DNS 历史证据');
    expect(core.state, NetworkCheckState.skipped);
    expect(core.detail, contains('没有可用'));
  });

  test(
    'native engine does not inspect the inactive Mihomo DNS snapshot',
    () async {
      var called = false;
      final checks =
          await DesktopNetworkDiagnostics(
            coreHealth: () async {
              called = true;
              return {};
            },
            systemDns: (_) async => [InternetAddress('93.184.215.14')],
            windowsRoutes: () async => '',
          ).run(
            engine: 'sing-box',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: true,
            proxyPort: null,
            tunConfigured: true,
          );
      expect(called, isFalse);
      expect(
        checks.singleWhere((c) => c.title == 'Mihomo 内核 DNS 历史证据').state,
        NetworkCheckState.skipped,
      );
    },
  );

  test(
    'selected node DNS answer is not proof of a real upstream address',
    () async {
      String? queried;
      final checks =
          await DesktopNetworkDiagnostics(
            nodeDns: (name) async {
              queried = name;
              return {'state': 'answered'};
            },
            systemDns: (_) async => [InternetAddress('93.184.215.14')],
            windowsRoutes: () async => '',
          ).run(
            engine: 'Mihomo',
            running: true,
            switching: false,
            systemProxyEnabled: false,
            nativeSystemProxy: false,
            nativeEngine: false,
            proxyPort: null,
            tunConfigured: false,
            selectedNodeName: 'selected-leaf',
          );
      expect(queried, 'selected-leaf');
      final node = checks.singleWhere(
        (check) => check.title == '所选策略组节点入口 DNS（Mihomo）',
      );
      expect(node.state, NetworkCheckState.warning);
      expect(node.detail, contains('可能为 Fake-IP'));
      expect(node.detail, contains('未验证真实上游'));
    },
  );

  test('failed node entry DNS does not change Windows DNS result', () async {
    final checks =
        await DesktopNetworkDiagnostics(
          nodeDns: (_) async => {'state': 'failed'},
          systemDns: (_) async => [InternetAddress('93.184.215.14')],
          windowsRoutes: () async => '',
        ).run(
          engine: 'Mihomo',
          running: true,
          switching: false,
          systemProxyEnabled: false,
          nativeSystemProxy: false,
          nativeEngine: false,
          proxyPort: null,
          tunConfigured: false,
          selectedNodeName: 'selected-leaf',
        );
    expect(
      checks.singleWhere((check) => check.title == 'Windows 系统 DNS').state,
      NetworkCheckState.ok,
    );
    expect(
      checks
          .singleWhere((check) => check.title == '所选策略组节点入口 DNS（Mihomo）')
          .state,
      NetworkCheckState.failed,
    );
  });

  test('native engine and missing node never query Mihomo node DNS', () async {
    var calls = 0;
    final diagnostics = DesktopNetworkDiagnostics(
      nodeDns: (_) async {
        calls++;
        return {'state': 'answered'};
      },
      systemDns: (_) async => [InternetAddress('93.184.215.14')],
      windowsRoutes: () async => '',
    );
    for (final (native, name) in [(true, 'selected-leaf'), (false, '')]) {
      final checks = await diagnostics.run(
        engine: native ? 'sing-box' : 'Mihomo',
        running: true,
        switching: false,
        systemProxyEnabled: false,
        nativeSystemProxy: false,
        nativeEngine: native,
        proxyPort: null,
        tunConfigured: false,
        selectedNodeName: name,
      );
      expect(
        checks
            .singleWhere((check) => check.title == '所选策略组节点入口 DNS（Mihomo）')
            .state,
        NetworkCheckState.skipped,
      );
    }
    expect(calls, 0);
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
