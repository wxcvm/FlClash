import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto probes keep the incumbent and fastest known alternatives', () {
    final candidates = automaticSpeedCandidates(
      ['a', 'b', 'c', 'd', 'e', 'f'],
      'd',
      {'b': 900, 'c': 800, 'a': 500},
      4,
    );
    expect(candidates, ['d', 'b', 'c', 'e']);
  });

  test('bounded auto probes explore different candidates', () {
    const names = ['a', 'b', 'c', 'd', 'e', 'f'];
    expect(automaticSpeedCandidates(names, 'a', {}, 1), ['a', 'b', 'c', 'd']);
    expect(automaticSpeedCandidates(names, 'a', {}, 3), ['a', 'd', 'e', 'f']);
    expect(automaticSpeedCandidates(['a', 'b'], 'a', {}, 0), ['a', 'b']);
    expect(automaticSpeedCandidates([], '', {}, 0), isEmpty);
  });
}
