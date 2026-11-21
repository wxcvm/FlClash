import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Karing does not appear in FlClash navigation', () {
    for (final openLogs in [false, true]) {
      for (final hasProxies in [false, true]) {
        final items = Navigation().getItems(
          openLogs: openLogs,
          hasProxies: hasProxies,
        );

        expect(
          items.any((item) => item.label == PageLabel.karing),
          isFalse,
        );
      }
    }
  });
}
