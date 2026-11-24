import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';

import 'native_core.dart';

/// An explicitly configured, authenticated local sing-box Clash API.
final class NativeClashController {
  NativeClashController._(this._port, this._secret);

  final int _port;
  final String _secret;

  static NativeClashController? fromConfig(Object? config) {
    final experimental = config is Map ? config['experimental'] : null;
    final api = experimental is Map ? experimental['clash_api'] : null;
    if (api is! Map) return null;
    final address = api['external_controller'];
    final secret = api['secret'];
    if (address is! String || secret is! String || secret.trim().isEmpty) {
      return null;
    }
    final match = RegExp(r'^127\.0\.0\.1:([0-9]{1,5})$').firstMatch(address);
    final port = int.tryParse(match?.group(1) ?? '');
    if (port == null || port < 1 || port > 65535) return null;
    return NativeClashController._(port, secret);
  }

  static Future<NativeClashController?> fromSpec(NativeCoreSpec spec) async {
    if (spec.kind != NativeCoreKind.singBox) return null;
    return fromConfig(
      jsonDecode(await File(spec.absoluteConfigPath).readAsString()),
    );
  }

  Future<Map<String, dynamic>> _read(String path) async {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: path),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('Native controller HTTP ${response.statusCode}');
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (buffer.length + chunk.length > 8 * 1024 * 1024) {
            throw const FormatException('Native controller response too large');
          }
          buffer.add(chunk);
        }
        final data = jsonDecode(utf8.decode(buffer.takeBytes()));
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Invalid native controller response');
        }
        return data;
      })().timeout(const Duration(seconds: 5));
    } finally {
      client.close(force: true);
    }
  }

  Future<List<TrackerInfo>> connections() async =>
      nativeClashConnections(await _read('/connections'));

  Future<Map<String, String>> selections() async {
    final data = await _read('/proxies');
    final proxies = data['proxies'];
    if (proxies is! Map) {
      throw const FormatException('Invalid native proxy snapshot');
    }
    return {
      for (final entry in proxies.entries)
        if (entry.key is String &&
            entry.key != 'GLOBAL' &&
            entry.value is Map &&
            entry.value['all'] is List &&
            entry.value['now'] is String)
          entry.key as String: entry.value['now'] as String,
    };
  }
}

/// sing-box supplies chains in exit-first order, just like Mihomo.
/// Normalize the optional metadata without inventing a route or timestamp.
List<TrackerInfo> nativeClashConnections(Map<String, dynamic> snapshot) {
  final rows = snapshot['connections'];
  if (rows is! List) {
    throw const FormatException('Invalid native connection snapshot');
  }
  return rows.map((row) {
    if (row is! Map || row['id'] is! String || row['start'] is! String) {
      throw const FormatException('Invalid native connection row');
    }
    final start = DateTime.tryParse(row['start'] as String);
    final chains = row['chains'];
    if (start == null ||
        (chains != null &&
            (chains is! List || chains.any((tag) => tag is! String)))) {
      throw const FormatException('Invalid native connection metadata');
    }
    final metadata = row['metadata'];
    if (metadata is! Map) {
      throw const FormatException('Missing native connection metadata');
    }
    String field(Map data, String key) =>
        data[key] is String ? data[key] as String : '';
    int bytes(String key) {
      final value = row[key];
      return value is int && value >= 0 ? value : 0;
    }

    final path = field(metadata, 'processPath');
    final process = field(metadata, 'process');
    return TrackerInfo(
      id: row['id'] as String,
      start: start,
      chains: List<String>.from(chains as List? ?? const []),
      upload: bytes('upload'),
      download: bytes('download'),
      rule: field(row, 'rule'),
      rulePayload: field(row, 'rulePayload'),
      metadata: Metadata(
        network: field(metadata, 'network'),
        sourceIP: field(metadata, 'sourceIP'),
        sourcePort: field(metadata, 'sourcePort'),
        destinationIP: field(metadata, 'destinationIP'),
        destinationPort: field(metadata, 'destinationPort'),
        host: field(metadata, 'host'),
        process: process.isEmpty ? path : process,
        processPath: path,
      ),
    );
  }).toList();
}
