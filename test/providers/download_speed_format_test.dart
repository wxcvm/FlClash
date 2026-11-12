import 'package:fl_clash/providers/download_speed.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DNS failure pauses automatic selection until rechecked', () {
    final now = DateTime(2026);
    final health = {
      'state': 'dns-failure',
      'dns': 'failed',
      'checked-at': now.millisecondsSinceEpoch,
    };
    expect(networkHealthGate(health, now), NetworkHealthGate.wait);
    expect(
      networkHealthGate(health, now.add(const Duration(minutes: 2))),
      NetworkHealthGate.refresh,
    );
    expect(
      networkHealthGate({
        'state': 'reachable',
        'dns': 'untested',
        'checked-at': now.millisecondsSinceEpoch,
      }, now),
      NetworkHealthGate.allow,
    );
  });

  test('failover requires a current diagnostic but keeps node checks', () {
    final now = DateTime(2026);
    expect(
      networkHealthGate({'state': 'idle'}, now, requireRecent: true),
      NetworkHealthGate.refresh,
    );
    expect(
      networkHealthGate({'state': 'checking'}, now),
      NetworkHealthGate.wait,
    );
    expect(
      networkHealthGate(
        {
          'state': 'inconclusive',
          'dns': 'untested',
          'checked-at': now.millisecondsSinceEpoch,
        },
        now,
        requireRecent: true,
      ),
      NetworkHealthGate.wait,
    );
    expect(
      networkHealthGate(
        {
          'state': 'route-unreachable',
          'dns': 'resolved',
          'checked-at': now.millisecondsSinceEpoch,
        },
        now,
        requireRecent: true,
      ),
      NetworkHealthGate.allow,
    );
  });

  test('IP endpoints do not need DNS to authorize node checks', () {
    final now = DateTime(2026);
    final health = {
      'state': 'route-unreachable',
      'dns': 'not-required',
      'checked-at': now.millisecondsSinceEpoch,
    };
    expect(
      networkHealthGate(health, now, requireRecent: true),
      NetworkHealthGate.allow,
    );
    expect(
      networkHealthGate(
        {...health, 'dns': 'untested'},
        now,
        requireRecent: true,
      ),
      NetworkHealthGate.wait,
    );
  });

  test('health checks require two failures and ignore unknown results', () {
    final health = NodeHealthHistory();
    final now = DateTime(2026);
    expect(health.record('A', 30, now), NodeHealthDecision.optimize);
    health.markOptimization(now);
    expect(health.record('A', -1, now), NodeHealthDecision.wait);
    expect(health.record('A', null, now), NodeHealthDecision.wait);
    expect(health.record('A', -2, now), NodeHealthDecision.failover);
    expect(health.samples['A'], (successes: 1, failures: 2));
    expect(health.record('B', -1, now), NodeHealthDecision.wait);
    health.reset();
    expect(health.samples, isEmpty);
    expect(health.record('A', -1, now), NodeHealthDecision.wait);
  });

  test('network changes reset health but keep download budget', () {
    final health = NodeHealthHistory();
    final now = DateTime(2026);
    health.markOptimization(now);
    health.record('A', -1, now);
    health.reset(keepOptimizationBudget: true);
    expect(health.samples, isEmpty);
    expect(health.record('A', 30, now), NodeHealthDecision.wait);
    expect(
      health.record('A', 30, now.add(const Duration(minutes: 30))),
      NodeHealthDecision.optimize,
    );
  });

  test('health success clears failures and optimization is rate limited', () {
    final health = NodeHealthHistory();
    final now = DateTime(2026);
    health.markOptimization(now);
    expect(health.record('A', -1, now), NodeHealthDecision.wait);
    expect(health.record('A', 50, now), NodeHealthDecision.wait);
    expect(health.record('A', -1, now), NodeHealthDecision.wait);
    expect(
      health.record('A', 50, now.add(const Duration(minutes: 30))),
      NodeHealthDecision.optimize,
    );
  });

  test('speed group activity is independent and clears on completion', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final groups = container.read(downloadSpeedTestingGroupsProvider.notifier);
    groups.start('A');
    groups.start('B');
    expect(container.read(downloadSpeedTestingGroupsProvider), {'A', 'B'});
    groups.stop('A');
    expect(container.read(downloadSpeedTestingGroupsProvider), {'B'});
    groups.stop('B');
    expect(container.read(downloadSpeedTestingGroupsProvider), isEmpty);
  });

  test('download speeds use decimal byte units', () {
    expect(formatDownloadSpeed(512), '512 B/s');
    expect(formatDownloadSpeed(125000), '125.0 KB/s');
    expect(formatDownloadSpeed(12500000), '12.5 MB/s');
  });
}
