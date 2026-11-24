import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'native_core.dart';
import 'windows_ipv4_routes.dart';

/// A local HTTP-compatible listener that the OS proxy can safely point to.
/// This intentionally excludes SOCKS-only, wildcard-bound and authenticated
/// inbounds: FlClash's current system proxy integration cannot use them.
final class NativeHttpEndpoint {
  final int port;

  const NativeHttpEndpoint(this.port);
}

/// Do not translate the native configuration: only discover a single
/// explicitly loopback-bound HTTP or mixed inbound.
Future<NativeHttpEndpoint?> detectNativeHttpEndpoint(
  NativeCoreSpec spec,
) async {
  if (spec.kind == NativeCoreKind.hysteria2) {
    try {
      final config = loadYaml(
        await File(spec.absoluteConfigPath).readAsString(),
      );
      if (config is! YamlMap) return null;
      final http = config['http'];
      if (http is! YamlMap ||
          http['username'] != null ||
          http['password'] != null) {
        return null;
      }
      final listen = http['listen'];
      if (listen is! String) return null;
      final match = RegExp(r'^127\.0\.0\.1:([0-9]{1,5})$').firstMatch(listen);
      final port = int.tryParse(match?.group(1) ?? '');
      if (port != null && port >= 1 && port <= 65535) {
        return NativeHttpEndpoint(port);
      }
    } on Exception {
      return null;
    }
    return null;
  }
  final Object? json;
  try {
    json = jsonDecode(await File(spec.absoluteConfigPath).readAsString());
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final inbounds = json['inbounds'];
  if (inbounds is! List) return null;

  final matches = <NativeHttpEndpoint>[];
  for (final inbound in inbounds) {
    if (inbound is! Map || inbound['listen'] != '127.0.0.1') continue;
    final Object? port;
    switch (spec.kind) {
      case NativeCoreKind.singBox:
        if (inbound['type'] != 'mixed' && inbound['type'] != 'http') continue;
        if (inbound['users'] case final List users when users.isNotEmpty) {
          continue;
        }
        port = inbound['listen_port'];
      case NativeCoreKind.hysteria2:
        continue;
      case NativeCoreKind.xray:
        if (inbound['protocol'] != 'http') continue;
        final settings = inbound['settings'];
        final accounts = settings is Map ? settings['accounts'] : null;
        if (accounts is List && accounts.isNotEmpty) {
          continue;
        }
        port = inbound['port'];
    }
    if (port is int && port >= 1 && port <= 65535) {
      matches.add(NativeHttpEndpoint(port));
    }
  }
  // Do not guess the intended OS proxy if several HTTP inbounds exist.
  return matches.length == 1 ? matches.single : null;
}

/// A single sing-box TUN inbound configured to route system traffic.
/// Detecting configuration is not proof that the OS has installed the route.
final class NativeTunConfiguration {
  final String? interfaceName;
  final String? dnsMode;
  final List<String> ipv4Addresses;

  const NativeTunConfiguration({
    this.interfaceName,
    this.dnsMode,
    this.ipv4Addresses = const [],
  });
}

Future<NativeTunConfiguration?> detectNativeTunConfiguration(
  NativeCoreSpec spec,
) async {
  // Xray-core has no equivalent built-in TUN inbound.
  if (spec.kind != NativeCoreKind.singBox) return null;
  final Object? json;
  try {
    json = jsonDecode(await File(spec.absoluteConfigPath).readAsString());
  } on FormatException {
    return null;
  }
  if (json is! Map || json['inbounds'] is! List) return null;
  final inbounds = json['inbounds'] as List;
  final routedTun = inbounds.where(
    (inbound) =>
        inbound is Map &&
        inbound['type'] == 'tun' &&
        inbound['auto_route'] == true,
  );
  if (routedTun.length != 1) return null;
  final inbound = routedTun.single as Map;
  final addresses = inbound['address'];
  final ipv4 = <String>{};
  if (addresses is List) {
    for (final value in addresses) {
      if (value is! String) continue;
      final address = InternetAddress.tryParse(value.split('/').first);
      if (address?.type == InternetAddressType.IPv4) {
        ipv4.add(address!.address);
      }
    }
  }
  return NativeTunConfiguration(
    ipv4Addresses: List.unmodifiable(ipv4),
    interfaceName: inbound['interface_name'] is String
        ? inbound['interface_name'] as String
        : null,
    dnsMode: inbound['dns_mode'] is String
        ? inbound['dns_mode'] as String
        : null,
  );
}

/// Check that the loopback port is free after Mihomo stops and before
/// starting the external core. Otherwise another process could satisfy the
/// readiness probe and receive system proxy traffic.
Future<bool> isNativeHttpPortAvailable(NativeHttpEndpoint endpoint) async {
  try {
    final listener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      endpoint.port,
      shared: false,
    );
    await listener.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Wait until the native process actually exposes its HTTP port. A successful
/// Process.start only means spawn succeeded, not that listeners are ready.
Future<bool> waitForNativeHttpEndpoint(
  NativeHttpEndpoint endpoint, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        endpoint.port,
        timeout: const Duration(milliseconds: 250),
      );
      socket.destroy();
      return true;
    } on Exception {
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }
  return false;
}


/// Verify only the presence of a configured IPv4 interface in active routes.
/// This does not prove default-route coverage, DNS, or remote connectivity.
Future<bool?> waitForWindowsNativeTun(
  NativeTunConfiguration tun, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (tun.ipv4Addresses.isEmpty) return null;
  final watch = Stopwatch()..start();
  do {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) break;
    try {
      final result = await Process.run('route', [
        'print',
        '-4',
      ]).timeout(remaining);
      if (result.exitCode == 0 &&
          windowsHasNativeTunAddress(
            result.stdout.toString(),
            tun.ipv4Addresses,
          )) {
        return true;
      }
    } on Exception {
      // An unavailable route query cannot establish readiness.
    }
    if (watch.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  } while (watch.elapsed < timeout);
  return false;
}
