import 'dart:convert';
import 'dart:io';

import 'native_core.dart';

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

  const NativeTunConfiguration({this.interfaceName, this.dnsMode});
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
  return NativeTunConfiguration(
    interfaceName: inbound['interface_name'] is String
        ? inbound['interface_name'] as String
        : null,
    dnsMode: inbound['dns_mode'] is String
        ? inbound['dns_mode'] as String
        : null,
  );
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
