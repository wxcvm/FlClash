import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Karing does not appear in FlClash navigation or More tools', () {
    for (final openLogs in [false, true]) {
      for (final hasProxies in [false, true]) {
        final items = Navigation().getItems(
          openLogs: openLogs,
          hasProxies: hasProxies,
        );

        expect(items.map((item) => item.label), isNot(contains(PageLabel.karing)));
        expect(
          items.where((item) => item.modes.contains(NavigationItemMode.moreFull))
              .map((item) => item.label),
          isNot(contains(PageLabel.karing)),
        );
      }
    }
  });
}
