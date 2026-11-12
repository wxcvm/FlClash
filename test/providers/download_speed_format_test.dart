import 'package:fl_clash/providers/download_speed.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speed group activity is independent and clears on completion', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final groups = container.read(downloadSpeedTestingGroupsProvider.notifier);
    groups.start('A');
    groups.start('B');
    expect(container.read(downloadSpeedTestingGroupsProvider), {'A', 'B'});
    groups.stop('A');
    expect(container.read(downloadSpeedTestingGroupsProvider), {'B'});
    groups.stop('B');
    expect(container.read(downloadSpeedTestingGroupsProvider), isEmpty);
  });

  test('download speeds use decimal byte units', () {
    expect(formatDownloadSpeed(512), '512 B/s');
    expect(formatDownloadSpeed(125000), '125.0 KB/s');
    expect(formatDownloadSpeed(12500000), '12.5 MB/s');
  });
}
