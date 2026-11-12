import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('small speed gains keep the incumbent', () {
    expect(
      chooseDownloadSpeedWinner({'current': 100, 'other': 119}, 'current'),
      'current',
    );
  });

  test('explicit fastest selection does not apply automatic hysteresis', () {
    expect(
      chooseDownloadSpeedWinner({
        'current': 100,
        'other': 119,
      }, 'current', automatic: false),
      'other',
    );
  });

  test('a 20 percent gain warrants a switch', () {
    expect(
      chooseDownloadSpeedWinner({'current': 100, 'other': 120}, 'current'),
      'other',
    );
  });

  test('a failed incumbent does not prevent failover', () {
    expect(
      chooseDownloadSpeedWinner({'current': 0, 'other': 50}, 'current'),
      'other',
    );
    expect(chooseDownloadSpeedWinner({'current': 0}, 'current'), isNull);
    expect(chooseDownloadSpeedWinner({}, 'current'), isNull);
  });
}
