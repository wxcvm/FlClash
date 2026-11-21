import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'yaml.dart';

/// A deliberately narrow wg-quick reader for a single full-tunnel peer.
///
/// This converts a WireGuard client file into a *Mihomo outbound proxy*, not
/// into a system WireGuard interface. Unsupported routing, hooks and multiple
/// peers are rejected rather than silently changing the connection semantics.
final class WireGuardQuickImportException implements Exception {
  const WireGuardQuickImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Returns [bytes] unchanged for non-WireGuard input. For wg-quick input the
/// result is standard Mihomo YAML and goes through FlClash's normal core
/// validation and profile persistence path.
Uint8List convertWireGuardQuickFile(
  Uint8List bytes, {
  required String fileName,
}) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final proxy = parseWireGuardQuick(text, fileName: fileName);
  if (proxy == null) {
    return bytes;
  }
  return Uint8List.fromList(
    utf8.encode(yaml.encode({'proxies': [proxy]})),
  );
}

/// Returns null if [content] is not a wg-quick file at all.
Map<String, Object?>? parseWireGuardQuick(
  String content, {
  required String fileName,
}) {
  final text = content.replaceFirst('\uFEFF', '');
  final sectionPattern = RegExp(
    r'^\s*\[(Interface|Peer)\]\s*$',
    multiLine: true,
    caseSensitive: false,
  );
  if (!sectionPattern.hasMatch(text)) {
    return null;
  }

  final interface = <String, String>{};
  final peer = <String, String>{};
  Map<String, String>? current;
  var interfaceCount = 0;
  var peerCount = 0;
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      switch (line.substring(1, line.length - 1).trim().toLowerCase()) {
        case 'interface':
          if (++interfaceCount != 1) {
            throw const WireGuardQuickImportException(
              'Only one [Interface] section is supported.',
            );
          }
          current = interface;
        case 'peer':
          if (++peerCount != 1) {
            throw const WireGuardQuickImportException(
              'Multiple WireGuard peers cannot be imported as one proxy.',
            );
          }
          current = peer;
        default:
          throw const WireGuardQuickImportException(
            'Unsupported WireGuard section.',
          );
      }
      continue;
    }
    final equals = line.indexOf('=');
    if (current == null || equals <= 0) {
      throw const WireGuardQuickImportException(
        'Invalid WireGuard configuration line.',
      );
    }
    final key = line.substring(0, equals).trim().toLowerCase();
    final value = line.substring(equals + 1).trim();
    final allowed = identical(current, interface)
        ? const {'privatekey', 'address', 'dns', 'mtu'}
        : const {
            'publickey',
            'presharedkey',
            'endpoint',
            'allowedips',
            'persistentkeepalive',
          };
    if (!allowed.contains(key)) {
      throw const WireGuardQuickImportException(
        'Unsupported WireGuard option; routing hooks are not imported.',
      );
    }
    if (value.isEmpty) {
      throw const WireGuardQuickImportException(
        'A required WireGuard option value is empty.',
      );
    }
    if (current.containsKey(key)) {
      if (key == 'address' || key == 'allowedips' || key == 'dns') {
        current[key] = '${current[key]}, $value';
      } else {
        throw const WireGuardQuickImportException(
          'Duplicate WireGuard option.',
        );
      }
    } else {
      current[key] = value;
    }
  }

  if (interfaceCount != 1 || peerCount != 1) {
    throw const WireGuardQuickImportException(
      'WireGuard requires one [Interface] and one [Peer].',
    );
  }

  _validateKey(interface['privatekey'], 'PrivateKey');
  _validateKey(peer['publickey'], 'PublicKey');
  if (peer['presharedkey'] != null) {
    _validateKey(peer['presharedkey'], 'PresharedKey');
  }

  final addresses = _commaValues(interface['address']);
  if (addresses.isEmpty) {
    throw const WireGuardQuickImportException(
      'WireGuard Interface.Address is required.',
    );
  }
  String? ipv4;
  String? ipv6;
  for (final address in addresses) {
    final kind = _addressFamily(address);
    if (kind == InternetAddressType.IPv4) {
      if (ipv4 != null) {
        throw const WireGuardQuickImportException(
          'More than one IPv4 interface address is unsupported.',
        );
      }
      ipv4 = address;
    } else {
      if (ipv6 != null) {
        throw const WireGuardQuickImportException(
          'More than one IPv6 interface address is unsupported.',
        );
      }
      ipv6 = address;
    }
  }

  // Mihomo's single-peer outbound automatically uses full-tunnel allowed IPs.
  // Accept only matching full-tunnel wg-quick configurations; partial routes
  // or multiple peers require a separate routing-aware implementation.
  final allowedIPs = _commaValues(peer['allowedips']).toSet();
  final requiredAllowedIPs = {
    if (ipv4 != null) '0.0.0.0/0',
    if (ipv6 != null) '::/0',
  };
  if (allowedIPs.length != requiredAllowedIPs.length ||
      !allowedIPs.containsAll(requiredAllowedIPs)) {
    throw const WireGuardQuickImportException(
      'Only full-tunnel AllowedIPs matching the interface IP families '
      'are supported.',
    );
  }

  final endpoint = peer['endpoint'];
  if (endpoint == null) {
    throw const WireGuardQuickImportException(
      'WireGuard Peer.Endpoint is required.',
    );
  }
  final (server, port) = _parseEndpoint(endpoint);

  int? parseNumber(String? value, String label, int min, int max) {
    if (value == null) {
      return null;
    }
    final number = int.tryParse(value);
    if (number == null || number < min || number > max) {
      throw WireGuardQuickImportException('Invalid WireGuard $label.');
    }
    return number;
  }

  final mtu = parseNumber(interface['mtu'], 'MTU', 576, 9000);
  final keepalive = parseNumber(
    peer['persistentkeepalive'],
    'PersistentKeepalive',
    0,
    65535,
  );
  final dnsServers = _commaValues(interface['dns']);
  for (final server in dnsServers) {
    if (InternetAddress.tryParse(server) == null) {
      throw const WireGuardQuickImportException(
        'Only literal IP DNS servers are supported in WireGuard files.',
      );
    }
  }

  final rawName = fileName
      .split(RegExp(r'[/\\]'))
      .last
      .replaceFirst(RegExp(r'\.conf$', caseSensitive: false), '')
      .trim();
  final name = rawName.isEmpty ? 'WireGuard' : rawName;
  return {
    'name': name,
    'type': 'wireguard',
    'server': server,
    'port': port,
    if (ipv4 != null) 'ip': ipv4,
    if (ipv6 != null) 'ipv6': ipv6,
    'private-key': interface['privatekey'],
    'public-key': peer['publickey'],
    if (peer['presharedkey'] case final key?) 'pre-shared-key': key,
    if (mtu != null) 'mtu': mtu,
    if (keepalive != null) 'persistent-keepalive': keepalive,
    // This controls DNS resolution *inside the Mihomo outbound*. It is not a
    // request to replace FlClash's global or operating-system DNS settings.
    if (dnsServers.isNotEmpty) ...{
      'dns': dnsServers,
      'remote-dns-resolve': true,
    },
    'udp': true,
  };
}

void _validateKey(String? value, String label) {
  if (value == null) {
    throw WireGuardQuickImportException('WireGuard $label is required.');
  }
  try {
    if (base64.decode(value).length == 32) {
      return;
    }
  } on FormatException {
    // Keys are secrets: never include their values in errors or logs.
  }
  throw WireGuardQuickImportException('Invalid WireGuard $label.');
}

List<String> _commaValues(String? value) => value == null
    ? const []
    : [
        for (final item in value.split(','))
          if (item.trim().isNotEmpty) item.trim(),
      ];

InternetAddressType _addressFamily(String address) {
  final pieces = address.split('/');
  if (pieces.length != 2) {
    throw const WireGuardQuickImportException(
      'WireGuard interface addresses require a CIDR prefix.',
    );
  }
  final ip = InternetAddress.tryParse(pieces.first);
  final mask = int.tryParse(pieces.last);
  if (ip == null ||
      mask == null ||
      mask < 0 ||
      mask > (ip.type == InternetAddressType.IPv4 ? 32 : 128)) {
    throw const WireGuardQuickImportException(
      'Invalid WireGuard interface address.',
    );
  }
  return ip.type;
}

(String, int) _parseEndpoint(String value) {
  final host;
  final portString;
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1 || close + 1 >= value.length || value[close + 1] != ':') {
      throw const WireGuardQuickImportException(
        'Invalid bracketed WireGuard IPv6 endpoint.',
      );
    }
    host = value.substring(1, close);
    portString = value.substring(close + 2);
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
      throw const WireGuardQuickImportException(
        'Invalid WireGuard IPv6 endpoint.',
      );
    }
  } else {
    final colon = value.lastIndexOf(':');
    if (colon <= 0) {
      throw const WireGuardQuickImportException(
        'WireGuard Endpoint must include a port.',
      );
    }
    host = value.substring(0, colon);
    portString = value.substring(colon + 1);
    if (host.contains(':') || !_validHost(host)) {
      throw const WireGuardQuickImportException(
        'Invalid WireGuard Endpoint hostname.',
      );
    }
  }
  final port = int.tryParse(portString);
  if (port == null || port < 1 || port > 65535) {
    throw const WireGuardQuickImportException(
      'Invalid WireGuard Endpoint port.',
    );
  }
  return (host, port);
}

bool _validHost(String host) {
  if (InternetAddress.tryParse(host) != null) {
    return true;
  }
  if (host.isEmpty || host.length > 253 || host.contains('..')) {
    return false;
  }
  final labelPattern = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$');
  return host.split('.').every(
    (label) => label.length <= 63 && labelPattern.hasMatch(label),
  );
}
