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
    expect(routes.singleWhere((route) => route.hops.isEmpty).source,
        '192.0.2.1');
    expect(routes.where((route) => route.hops.contains('DIRECT')), hasLength(2));
  });

  test('empty snapshot contains no invented routes', () {
    expect(connectionRoutes([]), isEmpty);
  });
}
