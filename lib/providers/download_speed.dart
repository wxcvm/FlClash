import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'config.dart';
import 'route_state.dart';

final downloadSpeedTestingGroupsProvider =
    NotifierProvider<DownloadSpeedTestingGroups, Set<String>>(
      DownloadSpeedTestingGroups.new,
    );

class DownloadSpeedTestingGroups extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  void start(String name) {
    state = {...state, name};
  }

  void stop(String name) {
    state = {...state}..remove(name);
  }
}

/// An explicit, session-scoped opt-in for one URL-test group.
final downloadSpeedAutoGroupProvider =
    NotifierProvider<DownloadSpeedAutoGroup, String?>(
      DownloadSpeedAutoGroup.new,
    );

class DownloadSpeedAutoGroup extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(currentProfileIdProvider);
    return null;
  }

  void select(String? name) => state = name;
}

/// Missing entries are untested; zero means a completed unsuccessful test.
typedef DownloadSpeedSample = ({bool running, int bytesPerSecond});

final downloadSpeedResultsProvider =
    NotifierProvider<DownloadSpeedResults, Map<String, DownloadSpeedSample>>(
      DownloadSpeedResults.new,
    );

class DownloadSpeedResults extends Notifier<Map<String, DownloadSpeedSample>> {
  @override
  Map<String, DownloadSpeedSample> build() {
    ref.watch(currentProfileIdProvider);
    ref.watch(coreStatusProvider);
    ref.watch(routeTrackerProvider.select((route) => route.hostEpoch));
    return {};
  }

  void start(String name) {
    state = {...state, name: (running: true, bytesPerSecond: 0)};
  }

  void finish(String name, int bytesPerSecond) {
    state = {...state, name: (running: false, bytesPerSecond: bytesPerSecond)};
  }

  void discardRunning(String name) {
    if (state[name]?.running != true) {
      return;
    }
    state = {...state}..remove(name);
  }
}

/// Freeze the sorting inputs at the end of a batch, rather than moving cards
/// every time a measurement arrives.
final downloadSpeedSortSnapshotProvider =
    NotifierProvider<DownloadSpeedSortSnapshot, Map<String, int>>(
      DownloadSpeedSortSnapshot.new,
    );

class DownloadSpeedSortSnapshot extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    ref.watch(currentProfileIdProvider);
    ref.watch(coreStatusProvider);
    ref.watch(routeTrackerProvider.select((route) => route.hostEpoch));
    return {};
  }

  void publish(Map<String, DownloadSpeedSample> results) {
    state = {
      for (final entry in results.entries)
        if (!entry.value.running) entry.key: entry.value.bytesPerSecond,
    };
  }
}

String formatDownloadSpeed(int bytesPerSecond) {
  if (bytesPerSecond < 1000) {
    return '$bytesPerSecond B/s';
  }
  if (bytesPerSecond < 1000000) {
    return '${(bytesPerSecond / 1000).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / 1000000).toStringAsFixed(1)} MB/s';
}

enum NodeHealthDecision { wait, optimize, failover }

/// In-memory health history for the current profile and network. Unknown
/// results (RPC failure/cancelled probe) are not evidence of node failure.
class NodeHealthHistory {
  String? _node;
  int _failures = 0;
  DateTime? _lastOptimization;
  final Map<String, ({int successes, int failures})> _samples = {};

  Map<String, ({int successes, int failures})> get samples =>
      Map.unmodifiable(_samples);

  void reset({bool keepOptimizationBudget = false}) {
    _node = null;
    _failures = 0;
    if (!keepOptimizationBudget) _lastOptimization = null;
    _samples.clear();
  }

  NodeHealthDecision record(String node, int? delay, DateTime now) {
    if (_node != node) {
      _node = node;
      _failures = 0;
    }
    if (delay == null || delay == 0) return NodeHealthDecision.wait;
    final previous = _samples[node] ?? (successes: 0, failures: 0);
    final healthy = delay > 0;
    _samples[node] = (
      successes: previous.successes + (healthy ? 1 : 0),
      failures: previous.failures + (healthy ? 0 : 1),
    );
    if (!healthy) {
      _failures++;
      return _failures >= 2
          ? NodeHealthDecision.failover
          : NodeHealthDecision.wait;
    }
    _failures = 0;
    final last = _lastOptimization;
    return last == null || now.difference(last) >= const Duration(minutes: 30)
        ? NodeHealthDecision.optimize
        : NodeHealthDecision.wait;
  }

  void markOptimization(DateTime now) {
    _lastOptimization = now;
    _failures = 0;
  }
}

enum NetworkHealthGate { allow, wait, refresh }

/// The core already discards snapshots from old routes. DNS failures pause
/// automatic switching until a fresh diagnostic clears them; an old failure
/// requests a new check instead of blocking permanently. A failed endpoint
/// with successful DNS still needs the independent node health checks.
NetworkHealthGate networkHealthGate(
  Map<String, dynamic> health,
  DateTime now, {
  bool requireRecent = false,
}) {
  final state = health['state'];
  if (state == 'checking' || state == 'stopped') {
    return NetworkHealthGate.wait;
  }
  final checked = health['checked-at'];
  final age = checked is int ? now.millisecondsSinceEpoch - checked : -1;
  final recent = age >= 0 && age <= const Duration(minutes: 1).inMilliseconds;
  if (health['dns'] == 'failed') {
    return recent ? NetworkHealthGate.wait : NetworkHealthGate.refresh;
  }
  if (requireRecent) {
    if (!recent) return NetworkHealthGate.refresh;
    if (state != 'reachable' &&
        state != 'http-response' &&
        (state != 'route-unreachable' ||
            (health['dns'] != 'resolved' && health['dns'] != 'not-required'))) {
      return NetworkHealthGate.wait;
    }
  }
  return NetworkHealthGate.allow;
}
