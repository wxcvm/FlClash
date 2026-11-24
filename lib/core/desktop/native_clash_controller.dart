import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';

import 'native_core.dart';

/// An explicitly configured, authenticated local sing-box Clash API.
final class NativeProxyGroup {
  const NativeProxyGroup({
    required this.tag,
    required this.type,
    required this.selected,
    required this.members,
    this.selectedDelayMs,
  });

  final String tag;
  final String type;
  final String selected;
  final List<String> members;
  final int? selectedDelayMs;

  bool get selectable => type.toLowerCase() == 'selector';
}

final class NativeClashController {
  NativeClashController._(this._port, this._secret, this._testUrl);

  final int _port;
  final String _secret;
  final String _testUrl;

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
    final outbounds = config is Map ? config['outbounds'] : null;
    var testUrl = 'https://www.cloudflare.com/cdn-cgi/trace';
    if (outbounds is List) {
      for (final outbound in outbounds.whereType<Map>()) {
        final url = outbound['url'];
        if (outbound['type'] == 'urltest' && url is String) {
          final uri = Uri.tryParse(url);
          if (uri?.scheme == 'https' && uri!.host.isNotEmpty) {
            testUrl = url;
            break;
          }
        }
      }
    }
    return NativeClashController._(port, secret, testUrl);
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

  Future<List<NativeProxyGroup>> groups() async {
    final data = await _read('/proxies');
    final proxies = data['proxies'];
    if (proxies is! Map) {
      throw const FormatException('Invalid native proxy snapshot');
    }
    final groups = <NativeProxyGroup>[];
    for (final entry in proxies.entries) {
      if (entry.key is! String ||
          entry.key == 'GLOBAL' ||
          entry.value is! Map ||
          entry.value['type'] is! String ||
          entry.value['all'] is! List ||
          !entry.value['all'].every((tag) => tag is String) ||
          entry.value['now'] is! String) {
        continue;
      }
      final selected = entry.value['now'] as String;
      final selectedProxy = proxies[selected];
      final history = selectedProxy is Map ? selectedProxy['history'] : null;
      final latest = history is List && history.isNotEmpty
          ? history.first
          : null;
      final delay = latest is Map && latest['delay'] is num
          ? (latest['delay'] as num).toInt()
          : null;
      groups.add(
        NativeProxyGroup(
          tag: entry.key as String,
          type: entry.value['type'] as String,
          selected: selected,
          members: List<String>.unmodifiable(
            (entry.value['all'] as List).cast<String>(),
          ),
          selectedDelayMs: delay,
        ),
      );
    }
    return groups;
  }

  String get testUrl => _testUrl;

  Future<int> testDelay(String outbound) async {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client
          .getUrl(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: _port,
              pathSegments: ['proxies', outbound, 'delay'],
              queryParameters: {'url': _testUrl, 'timeout': '10000'},
            ),
          )
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (buffer.length + chunk.length > 64 * 1024) {
          throw const FormatException('Native delay response too large');
        }
        buffer.add(chunk);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Native delay HTTP ${response.statusCode}');
      }
      final data = jsonDecode(utf8.decode(buffer.takeBytes()));
      final delay = data is Map ? data['delay'] : null;
      if (delay is! num || delay <= 0) {
        throw const FormatException('Invalid native delay result');
      }
      return delay.toInt();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> select(String group, String outbound) async {
    final data = await _read('/proxies');
    final proxies = data['proxies'];
    final target = proxies is Map ? proxies[group] : null;
    if (target is! Map ||
        target['type']?.toString().toLowerCase() != 'selector' ||
        target['all'] is! List ||
        !(target['all'] as List).contains(outbound)) {
      throw StateError('The native selector or requested outbound changed');
    }

    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client
          .putUrl(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: _port,
              pathSegments: ['proxies', group],
            ),
          )
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': outbound}));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent) {
        throw HttpException('Native selector HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
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
