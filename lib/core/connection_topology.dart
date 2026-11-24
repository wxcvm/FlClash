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

enum TopologyRole { source, rule, group, exit }

typedef TopologyNodeKey = (int, TopologyRole, String);
typedef TopologyEdgeKey = (TopologyNodeKey, TopologyNodeKey);

class TopologyWeight {
  int connections = 0;
  int traffic = 0;

  void add(ConnectionRoute route) {
    connections += route.connections;
    traffic += route.traffic;
  }
}

/// Shared nodes are keyed by layer, role and name, so repeated names at
/// different depths never create a cycle. Edges represent observed adjacency.
class ConnectionGraph {
  ConnectionGraph(List<ConnectionRoute> routes, {int routeLimit = 40})
    : totalPaths = routes.length {
    final visible = routes.take(routeLimit).toList();
    for (final route in visible) {
      final keys = <TopologyNodeKey>[
        (0, TopologyRole.source, route.source),
        (1, TopologyRole.rule, route.rule),
        for (var i = 0; i < route.hops.length; i++)
          (
            i + 2,
            i == route.hops.length - 1
                ? TopologyRole.exit
                : TopologyRole.group,
            route.hops[i],
          ),
        if (route.hops.isEmpty) (2, TopologyRole.exit, ''),
      ];
      for (final key in keys) {
        nodes.putIfAbsent(key, TopologyWeight.new).add(route);
      }
      for (var i = 1; i < keys.length; i++) {
        edges.putIfAbsent((keys[i - 1], keys[i]), TopologyWeight.new).add(route);
      }
      shownPaths++;
      shownConnections += route.connections;
    }
  }

  final int totalPaths;
  int shownPaths = 0;
  int shownConnections = 0;
  final nodes = <TopologyNodeKey, TopologyWeight>{};
  final edges = <TopologyEdgeKey, TopologyWeight>{};
}
