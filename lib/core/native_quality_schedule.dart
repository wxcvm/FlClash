/// Session-local cadence for explicitly enabled foreground quality batches.
/// The caller owns its timer and pauses it while the dashboard is not visible.
class NativeQualitySchedule {
  static const interval = Duration(minutes: 15);
  static const networkSettle = Duration(seconds: 10);

  String? group;
  int revision = 0;
  DateTime? _due;

  void enable(String tag, DateTime now) {
    group = tag;
    revision++;
    _due = now;
  }

  void disable() {
    group = null;
    revision++;
    _due = null;
  }

  void networkChanged(DateTime now) {
    if (group == null) return;
    revision++;
    _due = now.add(networkSettle);
  }

  void complete(int startedRevision, DateTime now) {
    if (group == null || startedRevision != revision) return;
    _due = now.add(interval);
  }

  Duration? delay(DateTime now) {
    final due = _due;
    if (group == null || due == null) return null;
    final remaining = due.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }
}
