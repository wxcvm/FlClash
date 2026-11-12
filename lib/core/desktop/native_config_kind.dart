import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'native_core.dart';

/// Identifies a native client config by its schema, never its filename.
/// Unknown or mixed schemas require an explicit selection.
NativeCoreKind? detectNativeCoreKind(String source) {
  final Object? config;
  try {
    config = jsonDecode(source);
  } on FormatException {
    try {
      final yaml = loadYaml(source);
      return _isHysteriaClient(yaml) ? NativeCoreKind.hysteria2 : null;
    } on YamlException {
      return null;
    }
  }
  if (config is! Map) return null;
  if (_isHysteriaClient(config)) return NativeCoreKind.hysteria2;
  if (config.containsKey('proxies') ||
      config.containsKey('proxy-groups') ||
      config.containsKey('proxy-providers')) {
    return null;
  }
  var singBox = false;
  var xray = false;
  for (final key in ['inbounds', 'outbounds']) {
    final entries = config[key];
    if (entries is! List) continue;
    for (final entry in entries) {
      if (entry is! Map) continue;
      if (entry['type'] is String) singBox = true;
      if (entry['protocol'] is String) xray = true;
    }
  }
  if (singBox == xray) return null;
  return singBox ? NativeCoreKind.singBox : NativeCoreKind.xray;
}

bool _isHysteriaClient(Object? config) =>
    config is Map &&
    config['server'] is String &&
    (config['server'] as String).trim().isNotEmpty &&
    config['auth'] is String &&
    !config.containsKey('inbounds') &&
    !config.containsKey('outbounds') &&
    !config.containsKey('proxies') &&
    !config.containsKey('proxy-groups') &&
    !config.containsKey('proxy-providers');
