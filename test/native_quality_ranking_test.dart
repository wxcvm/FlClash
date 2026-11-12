import 'package:fl_clash/core/native_quality_ranking.dart';
import 'package:flutter_test/flutter_test.dart';

const now = 2000000;

NativeQualitySample sample(String tag, double speed, double latency, int time,
    {String state = 'done'}) => NativeQualitySample(
  tag: tag, state: state, downloadBps: speed, latencyMs: latency, startedAt: time,
);

void main() {
  test('actual download capacity wins over low latency alone', () {
    final rank = NativeQualityRanking()
      ..record(sample('fast', 100000000, 90, now - 1000))
      ..record(sample('slow', 2000000, 10, now - 1000));
    expect(rank.recommend(['slow', 'fast'], now: now), 'fast');
  });
  test('latest failed measurement excludes a node', () {
    final rank = NativeQualityRanking()
      ..record(sample('fast', 100000000, 10, now - 2000))
      ..record(sample('fast', 0, 0, now - 1000, state: 'failed'))
      ..record(sample('stable', 10000000, 50, now - 1000));
    expect(rank.recommend(['fast', 'stable'], now: now), 'stable');
  });
  test('median avoids one optimistic sample', () {
    final rank = NativeQualityRanking()
      ..record(sample('spiky', 1000000000, 20, now - 3000))
      ..record(sample('spiky', 1000000, 20, now - 2000))
      ..record(sample('spiky', 2000000, 20, now - 1000))
      ..record(sample('steady', 20000000, 30, now - 1000));
    expect(rank.recommend(['spiky', 'steady'], now: now), 'steady');
  });
  test('expired, canceled, unknown and invalid samples do not qualify', () {
    final rank = NativeQualityRanking()
      ..record(sample('expired', 100000000, 10, now - 901000))
      ..record(sample('canceled', 100000000, 10, now - 1000, state: 'canceled'))
      ..record(sample('invalid', double.nan, 10, now - 1000));
    expect(rank.recommend(['expired', 'canceled', 'invalid', 'unknown'], now: now), isNull);
  });
  test('repeat status reads do not inflate reliability', () {
    final rank = NativeQualityRanking()
      ..record(sample('a', 100000000, 20, now - 3000, state: 'failed'))
      ..record(sample('a', 100000000, 20, now - 1000))
      ..record(sample('a', 100000000, 20, now - 1000))
      ..record(sample('b', 30000000, 20, now - 1000));
    expect(rank.recommend(['a','b'], now: now), 'b');
    rank.clear();
    expect(rank.recommend(['a','b'], now: now), isNull);
  });
}
