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
  return createClashNativeCandidateFromYaml(
    await source.readAsString(),
    directory,
    inbounds: inbounds,
  );
}

Future<File> createClashNativeCandidateFromYaml(
  String yaml,
  Directory directory, {
  required List<Map<String, dynamic>> inbounds,
  Map<String, String> selected = const {},
}) async {
  final decoded = loadYaml(yaml);
  if (decoded is! Map) {
    throw const FormatException('Expected a Clash configuration');
  }
  final config = buildClashNativeConfig(
    Map<String, dynamic>.from(decoded),
    inbounds: inbounds,
    selected: selected,
  );
  final output = File('${directory.path}/config.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(config),
    flush: true,
  );
  return output;
}
