import 'dart:io';

import 'package:fl_clash/core/desktop/windows_ipv4_routes.dart';

typedef LocalPortProbe = Future<void> Function(int port);
typedef ProxiedHttpsProbe = Future<int> Function(int port);
typedef SystemDnsProbe = Future<List<InternetAddress>> Function(String host);
typedef WindowsRouteProbe = Future<String> Function();
typedef CoreHealthProbe = Future<Map<String, dynamic>> Function();
typedef NodeDnsProbe = Future<Map<String, dynamic>> Function(String name);
typedef NodeHttpsProbe = Future<Map<String, dynamic>> Function(String name);

enum NetworkCheckState { ok, warning, failed, skipped }

final class NetworkCheck {
  final String title;
  final NetworkCheckState state;
  final String detail;

  const NetworkCheck(this.title, this.state, this.detail);

  String get summary {
    final mark = switch (state) {
      NetworkCheckState.ok => '✓',
      NetworkCheckState.warning => '!',
      NetworkCheckState.failed => '✕',
      NetworkCheckState.skipped => '—',
    };
    return '$mark $title：$detail';
  }
}

final class DesktopNetworkDiagnostics {
  final LocalPortProbe localPort;
  final ProxiedHttpsProbe proxiedHttps;
  final SystemDnsProbe systemDns;
  final WindowsRouteProbe windowsRoutes;
  final CoreHealthProbe? coreHealth;
  final NodeDnsProbe? nodeDns;
  final NodeHttpsProbe? nodeHttps;

  DesktopNetworkDiagnostics({
    LocalPortProbe? localPort,
    ProxiedHttpsProbe? proxiedHttps,
    SystemDnsProbe? systemDns,
    WindowsRouteProbe? windowsRoutes,
    this.coreHealth,
    this.nodeDns,
    this.nodeHttps,
  }) : localPort = localPort ?? _checkLocalPort,
       proxiedHttps = proxiedHttps ?? _checkProxiedHttps,
       systemDns = systemDns ?? InternetAddress.lookup,
       windowsRoutes = windowsRoutes ?? _readWindowsRoutes;

  Future<List<NetworkCheck>> run({
    required String engine,
    required bool running,
    required bool switching,
    required bool systemProxyEnabled,
    required bool nativeSystemProxy,
    required bool nativeEngine,
    required int? proxyPort,
    required bool tunConfigured,
    bool followingWindowsDns = false,
    String? selectedNodeName,
  }) async {
    if (switching) {
      return const [
        NetworkCheck(
          '内核切换',
          NetworkCheckState.warning,
          '切换尚未结束，当前诊断可能过期，请完成后重新运行',
        ),
      ];
    }

    final checks = <NetworkCheck>[
      NetworkCheck(
        '内核',
        running ? NetworkCheckState.ok : NetworkCheckState.failed,
        running ? '$engine 进程或服务已启动' : '未检测到正在运行的内核',
      ),
      NetworkCheck(
        '系统代理',
        !systemProxyEnabled
            ? NetworkCheckState.skipped
            : nativeSystemProxy
            ? NetworkCheckState.ok
            : NetworkCheckState.warning,
        !systemProxyEnabled
            ? '当前未启用系统代理，手动代理端口仍可单独使用'
            : nativeSystemProxy
            ? '已写入系统代理设置，不代表远端连接可用'
            : nativeEngine
            ? '独立内核未接管系统代理（可能使用 TUN 或仅独立运行）'
            : 'Mihomo 配置已开启系统代理，当前 OS 设置未独立读取',
      ),
    ];

    if (!running || proxyPort == null || proxyPort < 1 || proxyPort > 65535) {
      checks.add(
        const NetworkCheck(
          '本地 HTTP 入口与代理 HTTPS',
          NetworkCheckState.skipped,
          '没有可检查的活动 HTTP 端口（TUN-only 不能用此项判断）',
        ),
      );
    } else {
      try {
        await localPort(proxyPort).timeout(const Duration(seconds: 3));
        checks.add(
          NetworkCheck(
            '本地 HTTP 入口',
            NetworkCheckState.ok,
            '127.0.0.1:$proxyPort 可建立 TCP 连接',
          ),
        );
        try {
          final status = await proxiedHttps(
            proxyPort,
          ).timeout(const Duration(seconds: 9));
          checks.add(
            NetworkCheck(
              '代理 HTTPS',
              status >= 200 && status < 400
                  ? NetworkCheckState.ok
                  : NetworkCheckState.warning,
              '经 127.0.0.1:$proxyPort 请求 Cloudflare，返回 HTTP $status',
            ),
          );
        } on Exception catch (error) {
          checks.add(
            NetworkCheck(
              '代理 HTTPS',
              NetworkCheckState.failed,
              '经代理请求 Cloudflare 失败：$error',
            ),
          );
        }
      } on Exception catch (error) {
        checks.add(
          NetworkCheck(
            '本地 HTTP 入口',
            NetworkCheckState.failed,
            '127.0.0.1:$proxyPort 无法连接：$error',
          ),
        );
        checks.add(
          const NetworkCheck(
            '代理 HTTPS',
            NetworkCheckState.skipped,
            '本地 HTTP 入口不可用，未发送远程请求',
          ),
        );
      }
    }

    try {
      final addresses = await systemDns(
        'example.com',
      ).timeout(const Duration(seconds: 4));
      if (addresses.isEmpty) throw const SocketException('Empty DNS answer');
      final answer = addresses.first.address;
      final fakeIp = RegExp(r'^198\.(18|19)\.').hasMatch(answer);
      checks.add(
        NetworkCheck(
          'Windows 系统 DNS',
          followingWindowsDns && fakeIp
              ? NetworkCheckState.warning
              : NetworkCheckState.ok,
          'example.com → $answer${fakeIp ? '（疑似 Fake-IP）' : ''}；'
              '仅验证系统解析，不代表代理内核 DNS 正常',
        ),
      );
    } on Exception catch (error) {
      checks.add(
        NetworkCheck(
          'Windows 系统 DNS',
          NetworkCheckState.failed,
          '系统解析 example.com 失败：$error；代理内核 DNS 未独立测试',
        ),
      );
    }

    if (followingWindowsDns) {
      if (!running) {
        checks.add(
          const NetworkCheck(
            'AdGuard DNS 查询日志',
            NetworkCheckState.skipped,
            'Mihomo 尚未运行；启动后再检查 AdGuard 实际是否接管 DNS',
          ),
        );
      } else {
        // A fresh hostname avoids a cached example.com result. A missing
        // address is expected: the AdGuard query log is the evidence.
        final host =
            'flclash-check-${DateTime.now().microsecondsSinceEpoch}.example.com';
        String outcome;
        try {
          await systemDns(host).timeout(const Duration(seconds: 5));
          outcome = '系统解析已返回';
        } on SocketException {
          outcome = '域名未解析出地址（测试域名通常没有记录）';
        } on Exception catch (error) {
          outcome = '系统查询未正常完成：$error';
        }
        checks.add(
          NetworkCheck(
            'AdGuard DNS 查询日志',
            NetworkCheckState.warning,
            '测试域名：$host；$outcome。请在 AdGuard DNS 查询日志搜索该完整域名；'
                '只有日志出现该请求才能确认由 AdGuard 接管',
          ),
        );
      }
    }

    if (coreHealth != null) {
      if (!running || nativeEngine) {
        checks.add(
          NetworkCheck(
            'Mihomo 内核 DNS 历史证据',
            NetworkCheckState.skipped,
            !running ? 'Mihomo 未运行，无法读取运行时快照' : '当前为独立内核，Mihomo 快照不适用',
          ),
        );
      } else {
        try {
          final snapshot = await coreHealth!().timeout(
            const Duration(seconds: 3),
          );
          final checkedAt = snapshot['checked-at'];
          final valid =
              checkedAt is int &&
              checkedAt > 0 &&
              snapshot['state'] != 'checking' &&
              snapshot['state'] != 'idle' &&
              snapshot['state'] != 'stopped';
          final dns = valid ? snapshot['dns'] : null;
          final evidence = switch (dns) {
            'resolved' => '前次测试地址失败后，核心独立 DNS 查询解析成功',
            'failed' => '前次测试地址失败后，核心独立 DNS 查询解析失败',
            'not-required' => '前次测试使用 IP 地址，无需解析',
            _ => '没有可用的核心独立 DNS 查询证据',
          };
          final time = valid
              ? DateTime.fromMillisecondsSinceEpoch(
                  checkedAt,
                ).toLocal().toIso8601String()
              : null;
          checks.add(
            NetworkCheck(
              'Mihomo 内核 DNS 历史证据',
              dns == 'resolved' || dns == 'failed'
                  ? NetworkCheckState.warning
                  : NetworkCheckState.skipped,
              '$evidence${time == null ? '' : '；记录时间：$time'}；'
                  '仅为此前一次测试地址的结果，不证明当前节点入口域名可解析',
            ),
          );
        } on Exception {
          checks.add(
            const NetworkCheck(
              'Mihomo 内核 DNS 历史证据',
              NetworkCheckState.warning,
              '无法读取内核历史快照；不代表 DNS 解析失败',
            ),
          );
        }
      }
    }

    if (nodeDns != null) {
      if (!running ||
          nativeEngine ||
          selectedNodeName == null ||
          selectedNodeName.isEmpty) {
        checks.add(
          NetworkCheck(
            '所选策略组节点入口 DNS（Mihomo）',
            NetworkCheckState.skipped,
            !running
                ? '内核未运行'
                : nativeEngine
                ? '独立内核不适用 Mihomo 查询'
                : '当前策略组没有可识别的选中节点',
          ),
        );
      } else {
        try {
          final result = await nodeDns!(
            selectedNodeName,
          ).timeout(const Duration(seconds: 7));
          final state = result['state'];
          final description = switch (state) {
            'answered' => 'Mihomo 解析器返回地址（可能为 Fake-IP，未验证真实上游或节点握手）',
            'failed' => 'Mihomo 解析器未能返回节点入口地址；不代表所有节点均不可用',
            'ip-address' => '节点入口已配置 IP 地址，无需域名解析',
            'no-endpoint' => '该节点没有可检查的标准服务器地址',
            'missing-node' => '诊断时未找到该节点，可能已更新订阅',
            'group' => '当前目标为策略组，未取得具体节点',
            'stale' => '检测时网络或路由已变化，结果作废',
            'stopped' => 'Mihomo 已停止',
            'no-selection' => '没有选中节点',
            _ => '未获得可判定的节点 DNS 结果',
          };
          checks.add(
            NetworkCheck(
              '所选策略组节点入口 DNS（Mihomo）',
              switch (state) {
                'failed' => NetworkCheckState.failed,
                'answered' || 'stale' => NetworkCheckState.warning,
                _ => NetworkCheckState.skipped,
              },
              '$description；此项只检查当前界面所选策略组的节点，'
                  '不代表所有规则流量或实际协议握手',
            ),
          );
        } on Exception {
          checks.add(
            const NetworkCheck(
              '所选策略组节点入口 DNS（Mihomo）',
              NetworkCheckState.warning,
              '查询未正常完成；不能据此判断节点入口 DNS 失败',
            ),
          );
        }
      }
    }

    if (nodeHttps != null) {
      if (!running ||
          nativeEngine ||
          selectedNodeName == null ||
          selectedNodeName.isEmpty) {
        checks.add(
          NetworkCheck(
            '所选策略组节点 HTTPS 通路（Mihomo）',
            NetworkCheckState.skipped,
            !running
                ? '内核未运行'
                : nativeEngine
                ? '独立内核不适用 Mihomo 查询'
                : '当前策略组没有可识别的选中节点',
          ),
        );
      } else {
        try {
          final result = await nodeHttps!(
            selectedNodeName,
          ).timeout(const Duration(seconds: 10));
          final state = result['state'];
          final status = result['http-status'];
          final code = status is int && status > 0 ? '；HTTP $status' : '';
          final description = switch (state) {
            'reachable' => '经所选节点收到 Cloudflare HTTPS 正常响应$code',
            'http-response' => '经所选节点收到 HTTPS 响应$code，但目标返回异常状态',
            'timeout' => '经所选节点请求 Cloudflare 超时',
            'failed' => '经所选节点请求 Cloudflare 失败，原因未能进一步分类',
            'busy' => '没有取得探针执行名额，未检测',
            'stale' => '检测时内核或节点已发生变化，结果作废',
            'stopped' => 'Mihomo 已停止',
            'missing-node' => '诊断时未找到该节点，可能已更新订阅',
            'group' => '当前目标为策略组，未取得具体节点',
            'no-selection' => '没有选中节点',
            _ => '未取得有效的 HTTPS 通路检测结果',
          };
          checks.add(
            NetworkCheck(
              '所选策略组节点 HTTPS 通路（Mihomo）',
              switch (state) {
                'reachable' => NetworkCheckState.ok,
                'timeout' || 'failed' => NetworkCheckState.failed,
                'http-response' || 'stale' => NetworkCheckState.warning,
                _ => NetworkCheckState.skipped,
              },
              '$description；仅验证当前所选节点至单一测试地址的 HTTPS 通路，'
                  '无法单凭失败结果断定节点协议握手或所有网站均不可用',
            ),
          );
        } on Exception {
          checks.add(
            const NetworkCheck(
              '所选策略组节点 HTTPS 通路（Mihomo）',
              NetworkCheckState.warning,
              '探针调用未完成，未能判断当前节点通路',
            ),
          );
        }
      }
    }

    try {
      final routes = await windowsRoutes().timeout(const Duration(seconds: 5));
      final defaultCount = RegExp(
        r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+',
        multiLine: true,
      ).allMatches(routes).length;
      final lowerHalf = RegExp(
        r'^\s*0\.0\.0\.0\s+128\.0\.0\.0\s+',
        multiLine: true,
      ).hasMatch(routes);
      final upperHalf = RegExp(
        r'^\s*128\.0\.0\.0\s+128\.0\.0\.0\s+',
        multiLine: true,
      ).hasMatch(routes);
      final coverage = running && tunConfigured && !nativeEngine
          ? inspectWindowsTunFakeIpRoute(routes)
          : null;
      checks.add(
        NetworkCheck(
          'IPv4 路由与 TUN',
          NetworkCheckState.warning,
          "${tunConfigured ? 'TUN 已配置' : 'TUN 未配置'}；"
              '默认路由 $defaultCount 条，'
              "成对 /1 分流${lowerHalf && upperHalf ? '存在' : '未发现'}。"
              '${coverage == null ? '' : '${coverage.detail}。'}'
              '只读路由快照不能证明流量实际由哪个内核接管',
        ),
      );
    } on Exception catch (error) {
      checks.add(
        NetworkCheck(
          'IPv4 路由与 TUN',
          NetworkCheckState.warning,
          '路由表无法读取：$error；TUN 所有权未验证',
        ),
      );
    }

    return checks;
  }
}

Future<void> _checkLocalPort(int port) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 2),
  );
  socket.destroy();
}

Future<int> _checkProxiedHttps(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
  try {
    final request = await client
        .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>().timeout(const Duration(seconds: 3));
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<String> _readWindowsRoutes() async {
  final result = await Process.run('route', [
    'print',
    '-4',
  ]).timeout(const Duration(seconds: 4));
  if (result.exitCode != 0) {
    throw ProcessException('route', ['print', '-4'], result.stderr.toString());
  }
  return result.stdout.toString();
}
