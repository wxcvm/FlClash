import 'dart:convert';

import 'package:fl_clash/models/models.dart';

/// A path reported by the core, not a network-level traceroute.
/// Mihomo returns chains exit-first (also used by the existing connection list).
class ConnectionRoute {
  ConnectionRoute({
    required this.source,
    required this.rule,
    required List<String> hops,
  }) : hops = List.unmodifiable(hops);

  final String source;
  final String rule;
  final List<String> hops;
  int connections = 0;
  int traffic = 0;

  String get key => jsonEncode([source, rule, hops]);
}

/// Group identical paths without discarding nested proxy groups or inventing
/// a direct route when the core has not supplied a chain.
List<ConnectionRoute> connectionRoutes(Iterable<TrackerInfo> connections) {
  final routes = <String, ConnectionRoute>{};
  for (final connection in connections) {
    final process = connection.metadata.process.trim();
    final candidate = ConnectionRoute(
      source: process.isEmpty ? connection.metadata.sourceIP : process,
      rule: connection.ruleText,
      hops: connection.chains.reversed.toList(),
    );
    final route = routes.putIfAbsent(candidate.key, () => candidate);
    route.connections++;
    route.traffic += connection.upload + connection.download;
  }
  return routes.values.toList()..sort((a, b) {
    final count = b.connections.compareTo(a.connections);
    return count != 0 ? count : a.key.compareTo(b.key);
  });
}
