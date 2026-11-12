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
