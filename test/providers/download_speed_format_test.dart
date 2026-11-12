import 'package:fl_clash/providers/download_speed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download speeds use decimal byte units', () {
    expect(formatDownloadSpeed(512), '512 B/s');
    expect(formatDownloadSpeed(125000), '125.0 KB/s');
    expect(formatDownloadSpeed(12500000), '12.5 MB/s');
  });
}
