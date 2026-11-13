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
  test('throughput advantage is not compressed away by latency', () {
    final rank = NativeQualityRanking()
      ..record(sample('fast', 100000000, 300, now - 1000))
      ..record(sample('slow', 50000000, 10, now - 1000));
    expect(rank.recommend(['slow', 'fast'], now: now), 'fast');
  });
  test('late arrival cannot override a newer failed measurement', () {
    final rank = NativeQualityRanking()
      ..record(sample('a', 0, 0, now - 1000, state: 'failed'))
      ..record(sample('a', 100000000, 10, now - 2000));
    expect(rank.recommend(['a'], now: now), isNull);
  });
  test('latest invalid completed measurement cannot recommend old speed', () {
    final rank = NativeQualityRanking()
      ..record(sample('a', 100000000, 10, now - 2000))
      ..record(sample('a', 0, 10, now - 1000));
    expect(rank.recommend(['a'], now: now), isNull);
  });
  test('rotation reaches every proxy while keeping current and measured best', () {
    final rank = NativeQualityRanking()
      ..record(sample('best', 100000000, 100, now - 1000));
    final names = ['current', 'best', 'low', 'medium', 'high'];
    final seen = <String>{};
    for (var cursor = 0; cursor < names.length; cursor++) {
      final candidates = rank.candidates(
        names, incumbent: 'current', cursor: cursor, now: now,
      );
      expect(candidates, hasLength(3));
      expect(candidates, containsAll(['current', 'best']));
      seen.addAll(candidates);
    }
    expect(seen, containsAll(names));
  });
  test('auto apply keeps incumbent without a clear improvement', () {
    expect(
      NativeQualityRanking.chooseAutoSwitch([
        sample('current', 10000000, 20, now - 2000),
        sample('candidate', 11000000, 20, now - 1000),
      ], incumbent: 'current', now: now),
      isNull,
    );
    expect(
      NativeQualityRanking.chooseAutoSwitch([
        sample('current', 10000000, 20, now - 2000),
        sample('candidate', 15000000, 20, now - 1000),
      ], incumbent: 'current', now: now),
      'candidate',
    );
  });
  test('auto apply needs fresh incumbent and a successful challenger', () {
    final good = sample('candidate', 15000000, 20, now - 1000);
    expect(NativeQualityRanking.chooseAutoSwitch(
      [good], incumbent: 'current', now: now,
    ), isNull);
    expect(NativeQualityRanking.chooseAutoSwitch([
      sample('current', 0, 0, now - 2000, state: 'failed'), good,
    ], incumbent: 'current', now: now), 'candidate');
    expect(NativeQualityRanking.chooseAutoSwitch([
      sample('current', 0, 0, now - 2000, state: 'canceled'), good,
    ], incumbent: 'current', now: now), isNull);
    expect(NativeQualityRanking.chooseAutoSwitch([
      sample('current', 0, 0, now - 901000, state: 'failed'), good,
    ], incumbent: 'current', now: now), isNull);
  });
  test('auto apply ignores a failed challenger and invalid incumbent', () {
    expect(NativeQualityRanking.chooseAutoSwitch([
      sample('current', 0, 20, now - 2000),
      sample('candidate', 15000000, 20, now - 1000),
    ], incumbent: 'current', now: now), isNull);
    expect(NativeQualityRanking.chooseAutoSwitch([
      sample('current', 10000000, 20, now - 2000),
      sample('candidate', 15000000, 20, now - 1500),
      sample('candidate', 0, 0, now - 1000, state: 'failed'),
    ], incumbent: 'current', now: now), isNull);
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
