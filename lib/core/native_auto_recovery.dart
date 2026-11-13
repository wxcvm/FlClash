import 'dart:convert';

/// Adds opt-in, native URLTest groups to a copy of a sing-box config.
/// No routing/default changes; the user explicitly selects the added member.
class NativeAutoRecoveryConfig {
  const NativeAutoRecoveryConfig(this.json, this.addedGroups);
  final String json;
  final List<String> addedGroups;
}

NativeAutoRecoveryConfig buildNativeAutoRecovery(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Native config must be a JSON object');
  }
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) {
    throw const FormatException('Native config has no outbounds');
  }
  final byTag = <String, Map<String, dynamic>>{};
  final occupied = <String>{};
  for (final item in outbounds) {
    if (item is! Map<String, dynamic>) continue;
    final tag = item['tag'];
    if (tag is String && tag.isNotEmpty) {
      if (!occupied.add(tag))
        throw const FormatException('Duplicate outbound tag');
      byTag[tag] = item;
    }
  }
  for (final key in ['endpoints', 'inbounds']) {
    final items = decoded[key];
    if (items is List) {
      for (final item in items) {
        if (item is Map && item['tag'] is String) {
          occupied.add(item['tag'] as String);
        }
      }
    }
  }

  // A proxy must represent a remote server, not a direct/block/nested group.
  const proxyTypes = {
    'shadowsocks',
    'vmess',
    'vless',
    'trojan',
    'hysteria',
    'hysteria2',
    'tuic',
    'socks',
    'http',
    'ssh',
    'anytls',
    'naive',
    'mieru',
  };
  final additions = <Map<String, dynamic>>[];
  for (final selector in byTag.values) {
    if (selector['type'] != 'selector') continue;
    final members = selector['outbounds'];
    if (members is! List) continue;
    if (members.any((tag) => byTag[tag]?['type'] == 'urltest')) continue;
    final eligible = members
        .whereType<String>()
        .where((tag) {
          final proxy = byTag[tag];
          return proxy != null &&
              proxyTypes.contains(proxy['type']) &&
              proxy['server'] is String &&
              (proxy['server'] as String).isNotEmpty;
        })
        .toSet()
        .take(5)
        .toList();
    if (eligible.length < 2) continue;
    final base = 'FlClash Auto · ${selector['tag']}';
    var tag = base;
    var suffix = 2;
    while (!occupied.add(tag)) {
      tag = '$base ${suffix++}';
    }
    additions.add({
      'type': 'urltest',
      'tag': tag,
      'outbounds': eligible,
      'interval': '3m',
      'tolerance': 100,
      'idle_timeout': '15m',
      'interrupt_exist_connections': false,
    });
    // Append only; preserve original first member, default and route rules.
    selector['outbounds'] = [...members, tag];
  }
  if (additions.isEmpty) {
    throw const FormatException(
      'No selector with at least two eligible proxies and no existing auto group',
    );
  }
  decoded['outbounds'] = [...outbounds, ...additions];
  return NativeAutoRecoveryConfig(
    const JsonEncoder.withIndent('  ').convert(decoded),
    additions.map((group) => group['tag'] as String).toList(),
  );
}
