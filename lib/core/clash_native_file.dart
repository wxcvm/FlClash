import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'clash_native_conversion.dart';

/// Writes a separate candidate; the source subscription is never modified.
Future<File> createClashNativeCandidate(
  File source,
  Directory directory, {
  required List<Map<String, dynamic>> inbounds,
}) async {
  final decoded = loadYaml(await source.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Expected a Clash configuration');
  }
  final config = buildClashNativeConfig(
    Map<String, dynamic>.from(decoded),
    inbounds: inbounds,
  );
  final output = File('${directory.path}/config.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(config),
    flush: true,
  );
  return output;
}
