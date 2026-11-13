import 'package:fl_clash/core/native_quality_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13);

  test('opt-in runs immediately then waits fifteen minutes after completion', () {
    final schedule = NativeQualitySchedule();
    expect(schedule.delay(now), isNull);
    schedule.enable('main', now, selected: 'a');
    expect(schedule.delay(now), Duration.zero);
    final end = now.add(const Duration(seconds: 60));
    schedule.complete(schedule.revision, end);
    expect(schedule.delay(end), NativeQualitySchedule.interval);
    expect(schedule.delay(end.add(const Duration(minutes: 16))), Duration.zero);
  });

  test('network change invalidates old batch and debounces new evaluation', () {
    final schedule = NativeQualitySchedule()..enable('main', now, selected: 'a');
    final old = schedule.revision;
    schedule.networkChanged(now);
    schedule.complete(old, now);
    expect(schedule.delay(now), NativeQualitySchedule.networkSettle);
    schedule.networkChanged(now.add(const Duration(seconds: 4)));
    expect(schedule.delay(now.add(const Duration(seconds: 4))),
        NativeQualitySchedule.networkSettle);
  });

  test('external selection differs and stale apply cannot replace expectation', () {
    final schedule = NativeQualitySchedule()
      ..enable('main', now, selected: 'a');
    final old = schedule.revision;
    expect(schedule.matchesSelection('a'), isTrue);
    expect(schedule.matchesSelection('b'), isFalse);
    schedule.applied(old, 'b');
    expect(schedule.matchesSelection('b'), isTrue);
    schedule.networkChanged(now);
    schedule.applied(old, 'c');
    expect(schedule.matchesSelection('b'), isTrue);
  });

  test('stop and group change cannot be overridden by old completion', () {
    final schedule = NativeQualitySchedule()..enable('main', now, selected: 'a');
    final old = schedule.revision;
    schedule.disable();
    schedule.complete(old, now);
    expect(schedule.delay(now), isNull);
    schedule.enable('other', now, selected: 'b');
    schedule.complete(old, now);
    expect(schedule.group, 'other');
    expect(schedule.delay(now), Duration.zero);
  });
}
