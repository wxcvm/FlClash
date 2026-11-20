import 'dart:io';

/// One active-route row from the numeric columns of Windows `route print -4`.
/// Gateway text is deliberately ignored because it is localized.
final class WindowsIpv4Route {
  const WindowsIpv4Route({
    required this.network,
    required this.mask,
    required this.interfaceAddress,
    required this.metric,
  });

  final int network;
  final int mask;
  final String interfaceAddress;
  final int metric;

  int get prefixLength {
    var bits = mask;
    var count = 0;
    while (bits != 0) {
      count += bits & 1;
      bits >>= 1;
    }
    return count;
  }

  bool contains(int address) => (address & mask) == (network & mask);
}

int? _ipv4(String value) {
  final parsed = InternetAddress.tryParse(value);
  if (parsed == null || parsed.type != InternetAddressType.IPv4) {
    return null;
  }
  return parsed.rawAddress.fold<int>(
    0,
    (address, part) => (address << 8) | part,
  );
}

List<WindowsIpv4Route> parseWindowsIpv4Routes(String output) {
  final pattern = RegExp(
    r'^\s*(\S+)\s+(\S+)\s+\S+\s+(\S+)\s+(\d+)\s*$',
    multiLine: true,
  );
  final routes = <WindowsIpv4Route>[];
  for (final match in pattern.allMatches(output)) {
    final network = _ipv4(match[1]!);
    final mask = _ipv4(match[2]!);
    final interfaceAddress = match[3]!;
    final metric = int.tryParse(match[4]!);
    if (network == null ||
        mask == null ||
        _ipv4(interfaceAddress) == null ||
        metric == null) {
      continue;
    }
    routes.add(
      WindowsIpv4Route(
        network: network,
        mask: mask,
        interfaceAddress: interfaceAddress,
        metric: metric,
      ),
    );
  }
  return routes;
}

WindowsIpv4Route? bestWindowsRoute(
  List<WindowsIpv4Route> routes,
  String address,
) {
  final target = _ipv4(address);
  if (target == null) return null;
  WindowsIpv4Route? best;
  for (final route in routes) {
    if (!route.contains(target)) continue;
    if (best == null ||
        route.prefixLength > best.prefixLength ||
        (route.prefixLength == best.prefixLength &&
            route.metric < best.metric)) {
      best = route;
    }
  }
  return best;
}

/// Compare an address outside Mihomo's standard /30 interface subnet with
/// the interface subnet itself. This is a diagnostic sample, not proof that
/// every aggregated Windows route or the TUN listener remains healthy.
({bool? escaped, String detail}) inspectWindowsTunFakeIpRoute(String output) {
  final routes = parseWindowsIpv4Routes(output);
  final local = bestWindowsRoute(routes, '198.18.0.1');
  final sample = bestWindowsRoute(routes, '198.18.0.8');
  if (local == null || sample == null) {
    return (
      escaped: null,
      detail: '默认 Fake-IP 样本 198.18.0.8 的路由信息不足，无法判断 TUN 覆盖情况',
    );
  }

  final referenceIsTun =
      local.interfaceAddress == '198.18.0.1' &&
      local.prefixLength >= 30;
  if (!referenceIsTun) {
    return (
      escaped: null,
      detail: '未检测到标准 TUN /30 链路基准；'
          '198.18.0.8 当前经 ${sample.interfaceAddress}（/${sample.prefixLength}）。'
          '自定义 Fake-IP 网段需另行检查',
    );
  }

  final escaped = local.interfaceAddress != sample.interfaceAddress;
  return (
    escaped: escaped,
    detail: '默认 Fake-IP 样本 198.18.0.8 → ${sample.interfaceAddress}'
        '（/${sample.prefixLength}），TUN 基准 198.18.0.1；'
        '${escaped ? '路由出口不同，疑似 TUN 路由覆盖丢失' : '样本出口一致，不代表全部路由完整'}',
  );
}
