import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads the open connections into the log, after the samples it last kept.
class ConnectionPoller {
  var _samples = TrackerSamples.empty;
  Object? _lineage;
  var _reads = 0;
  var _shownRead = 0;

  Future<bool> read(
    WidgetRef ref, {
    required Future<List<TrackerInfo>> Function()? reader,
    required bool Function() mounted,
  }) async {
    final read = ++_reads;
    final log = ref.read(requestsProvider);
    final lineage = log.lineage;
    if (!identical(lineage, _lineage)) {
      _samples = TrackerSamples.empty;
      _lineage = lineage;
    }
    final poll = pollAfter(_samples, log.slotGenerations);
    final requestedAt = DateTime.now();
    try {
      final polled = reader != null
          ? poll(await reader())
          : ref.read(coreStatusProvider) == CoreStatus.connected
          ? poll(await ref.read(coreHandlerProvider).getConnections())
          : poll(const []);
      // A refresh after closing a connection can overlap a poll.
      if (!mounted()) {
        return false;
      }
      if (read < _shownRead) {
        return true;
      }
      final applied = ref
          .read(requestsProvider.notifier)
          .poll(polled, requestedAt: requestedAt, lineage: lineage);
      if (applied) {
        _shownRead = read;
        _samples = polled.samples;
      }
      return true;
    } catch (error) {
      if (read < _shownRead) {
        return true;
      }
      commonPrint.log(
        'updateConnections error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return false;
    }
  }
}
