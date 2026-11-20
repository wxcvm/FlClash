import 'dart:io';

typedef LocalPortProbe = Future<void> Function(int port);
typedef ProxiedHttpsProbe = Future<int> Function(int port);
typedef SystemDnsProbe = Future<List<InternetAddress>> Function(String host);
typedef WindowsRouteProbe = Future<String> Function();

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

  DesktopNetworkDiagnostics({
    LocalPortProbe? localPort,
    ProxiedHttpsProbe? proxiedHttps,
    SystemDnsProbe? systemDns,
    WindowsRouteProbe? windowsRoutes,
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
      checks.add(
        NetworkCheck(
          'IPv4 路由与 TUN',
          NetworkCheckState.warning,
          "${tunConfigured ? 'TUN 已配置' : 'TUN 未配置'}；"
              '默认路由 $defaultCount 条，'
              "成对 /1 分流${lowerHalf && upperHalf ? '存在' : '未发现'}。"
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
