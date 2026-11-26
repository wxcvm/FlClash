import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TrackerInfo connection(
    String id,
    List<String> chains, {
    String source = 'Browser',
    String rule = 'MATCH',
    int traffic = 10,
  }) => TrackerInfo(
    id: id,
    start: DateTime(2026),
    metadata: Metadata(process: source, sourceIP: '192.0.2.1'),
    chains: chains,
    rule: rule,
    rulePayload: '',
    upload: traffic,
  );

  test('groups identical observed routes and retains all nested groups', () {
    final routes = connectionRoutes([
      connection('1', ['US', 'Inner', 'Outer']),
      connection('2', ['US', 'Inner', 'Outer'], traffic: 20),
      connection('3', ['US', 'Other', 'Outer']),
    ]);
    expect(routes, hasLength(2));
    expect(routes.first.hops, ['Outer', 'Inner', 'US']);
    expect(routes.first.connections, 2);
    expect(routes.first.traffic, 30);
    expect(routes.last.connections, 1);
  });

  test('unknown chains remain distinct from confirmed DIRECT', () {
    final routes = connectionRoutes([
      connection('1', [], source: ''),
      connection('2', ['DIRECT'], source: ''),
      connection('3', ['DIRECT'], rule: 'DOMAIN'),
    ]);
    expect(routes, hasLength(3));
    expect(
      routes.singleWhere((route) => route.hops.isEmpty).source,
      '192.0.2.1',
    );
    expect(
      routes.where((route) => route.hops.contains('DIRECT')),
      hasLength(2),
    );
  });

  test('empty snapshot contains no invented routes', () {
    expect(connectionRoutes([]), isEmpty);
  });

  test(
    'shared nodes aggregate observed edges without losing nested groups',
    () {
      final graph = ConnectionGraph(
        connectionRoutes([
          connection('1', ['US', 'Inner', 'Outer']),
          connection('2', ['US', 'Inner', 'Outer'], traffic: 20),
          connection('3', ['JP', 'Inner', 'Outer']),
        ]),
      );
      const outer = (2, TopologyRole.group, 'Outer');
      const inner = (3, TopologyRole.group, 'Inner');
      const us = (4, TopologyRole.exit, 'US');
      const jp = (4, TopologyRole.exit, 'JP');
      expect(graph.nodes[inner]!.connections, 3);
      expect(graph.edges[(outer, inner)]!.traffic, 40);
      expect(graph.edges[(inner, us)]!.connections, 2);
      expect(graph.edges[(inner, jp)]!.connections, 1);
      expect(graph.edges.containsKey((outer, us)), isFalse);
    },
  );

  test('graph cap is explicit and unknown exit is not DIRECT', () {
    final routes = connectionRoutes([
      connection('1', []),
      connection('2', ['DIRECT']),
      connection('3', ['DIRECT']),
    ]);
    final graph = ConnectionGraph(routes, routeLimit: 1);
    expect(graph.totalPaths, 2);
    expect(graph.shownPaths, 1);
    expect(graph.shownConnections, 2);
    final full = ConnectionGraph(routes);
    expect(full.nodes[(2, TopologyRole.exit, '')]!.connections, 1);
    expect(full.nodes[(2, TopologyRole.exit, 'DIRECT')]!.connections, 2);
  });

  test('node focus keeps only complete observed paths', () {
    final routes = connectionRoutes([
      connection('1', ['US', 'Shared'], source: 'Browser'),
      connection('2', ['JP', 'Shared'], source: 'Chat'),
      connection('3', ['US', 'Other'], source: 'Chat'),
    ]);
    const browser = (0, TopologyRole.source, 'Browser');
    final focused = topologyRoutesFor(routes, browser);
    expect(focused, hasLength(1));
    final graph = ConnectionGraph(focused);
    expect(graph.nodes.containsKey((3, TopologyRole.exit, 'US')), isTrue);
    expect(graph.nodes.containsKey((3, TopologyRole.exit, 'JP')), isFalse);
    expect(
      topologyRoutesFor(routes, (2, TopologyRole.group, 'Shared')),
      hasLength(2),
    );
  });
}
