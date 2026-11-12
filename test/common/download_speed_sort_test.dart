import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('speed order uses real throughput and keeps equal scores stable', () {
    const proxies = [
      Proxy(name: 'unknown-a', type: 'ss'),
      Proxy(name: 'slow', type: 'ss'),
      Proxy(name: 'failed', type: 'ss'),
      Proxy(name: 'fast-a', type: 'ss'),
      Proxy(name: 'unknown-b', type: 'ss'),
      Proxy(name: 'fast-b', type: 'ss'),
    ];
    final sorted = sortByDownloadSpeed(proxies, {
      'fast-a': 2000,
      'fast-b': 2000,
      'slow': 1000,
      'failed': 0,
    });
    expect(sorted.map((proxy) => proxy.name), [
      'fast-a',
      'fast-b',
      'slow',
      'unknown-a',
      'unknown-b',
      'failed',
    ]);
    expect(sortByDownloadSpeed(proxies, {}), proxies);
  });
}
