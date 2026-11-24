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

/// Providers may represent account metadata as reachable proxy definitions.
final _subscriptionInfoName = RegExp(
  r'^\s*(剩余流量|流量剩余|套餐到期|订阅到期|到期时间|剩余时间)\s*[:：]',
);

bool isSubscriptionInfoProxyName(String name) =>
    _subscriptionInfoName.hasMatch(name);

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

  void clear() => state = {};
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

  void clear() => state = {};
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

/// Recent HTTP probe statistics, not packet loss or transport-level jitter.
class NodeProbeQuality {
  NodeProbeQuality(Iterable<int> values) : values = List.unmodifiable(values);

  final List<int> values;
  int get successes => values.where((value) => value > 0).length;
  int get failures => values.length - successes;
  double? get successRate =>
      values.isEmpty ? null : successes / values.length;

  double? get meanDelay {
    final valid = values.where((value) => value > 0).toList();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  /// Average absolute difference of adjacent successful probes only.
  double? get delayVariation {
    var sum = 0;
    var pairs = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i - 1] <= 0 || values[i] <= 0) continue;
      sum += (values[i] - values[i - 1]).abs();
      pairs++;
    }
    return pairs == 0 ? null : sum / pairs;
  }
}

enum NodeHealthDecision { wait, optimize, failover }

/// In-memory health history for the current profile and network. Unknown
/// results (RPC failure/cancelled probe) are not evidence of node failure.
class NodeHealthHistory {
  String? _node;
  int _failures = 0;
  DateTime? _lastOptimization;
  DateTime? _lastOptimizationAttempt;
  static const sampleLimit = 12;
  final _samples = <String, List<int>>{};

  Map<String, NodeProbeQuality> get quality => {
    for (final entry in _samples.entries)
      entry.key: NodeProbeQuality(entry.value),
  };

  Map<String, ({int successes, int failures})> get samples => {
    for (final entry in quality.entries)
      entry.key: (
        successes: entry.value.successes,
        failures: entry.value.failures,
      ),
  };

  void reset({bool keepOptimizationBudget = false}) {
    _node = null;
    _failures = 0;
    if (!keepOptimizationBudget) {
      _lastOptimization = null;
      _lastOptimizationAttempt = null;
    }
    _samples.clear();
  }

  /// Candidate observations do not modify incumbent failure streaks.
  void observe(String node, int? delay) {
    if (delay == null || delay == 0) return;
    final recent = _samples.putIfAbsent(node, () => []);
    recent.add(delay);
    if (recent.length > sampleLimit) recent.removeAt(0);
  }

  NodeHealthDecision record(String node, int? delay, DateTime now) {
    if (_node != node) {
      _node = node;
      _failures = 0;
    }
    if (delay == null || delay == 0) return NodeHealthDecision.wait;
    observe(node, delay);
    final healthy = delay > 0;
    if (!healthy) {
      _failures++;
      return _failures >= 2
          ? NodeHealthDecision.failover
          : NodeHealthDecision.wait;
    }
    _failures = 0;
    final last = _lastOptimization;
    final attempt = _lastOptimizationAttempt;
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      return NodeHealthDecision.wait;
    }
    if (attempt != null &&
        now.difference(attempt) < const Duration(minutes: 2)) {
      return NodeHealthDecision.wait;
    }
    return NodeHealthDecision.optimize;
  }

  // A failed or interrupted batch should not consume the full success budget.
  void markOptimizationAttempt(DateTime now) {
    _lastOptimizationAttempt = now;
  }

  void markOptimization(DateTime now) {
    _lastOptimization = now;
    _lastOptimizationAttempt = now;
    _failures = 0;
  }

  // Lightweight recovery does not spend the download optimization budget.
  void markFailoverAttempt() {
    _failures = 0;
  }
}

enum NetworkHealthGate { allow, wait, refresh }

/// The core already discards snapshots from old routes. DNS failures pause
/// automatic switching until a fresh diagnostic clears them; an old failure
/// requests a new check instead of blocking permanently. Failed DNS is
/// rechecked on the next normal 30-second health-monitor cycle, rather than
/// waiting for the full diagnostic freshness window. A failed endpoint
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
    return age >= 0 && age < const Duration(seconds: 30).inMilliseconds
        ? NetworkHealthGate.wait
        : NetworkHealthGate.refresh;
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
