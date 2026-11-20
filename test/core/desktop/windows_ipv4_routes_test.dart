import 'package:fl_clash/core/desktop/windows_ipv4_routes.dart';
import 'package:flutter_test/flutter_test.dart';

const _physical = '0.0.0.0 0.0.0.0 192.0.2.1 192.0.2.20 20\n';
const _tunLocal = '198.18.0.0 255.255.255.252 在链路上 198.18.0.1 256\n';
const _tunCoverage = '196.0.0.0 252.0.0.0 On-link 198.18.0.1 256\n';

void main() {
  test('reads localized Windows route rows without relying on headings', () {
    final finding = inspectWindowsTunFakeIpRoute(
      'IPv4 活动路由：\n'
      '网络目标 网络掩码 网关 接口 跃点数\n'
      '$_physical$_tunLocal$_tunCoverage',
    );
    expect(finding.escaped, isFalse);
    expect(finding.detail, contains('（/6）'));
  });

  test('missing aggregated Fake-IP coverage reports a different exit', () {
    final finding = inspectWindowsTunFakeIpRoute('$_physical$_tunLocal');
    expect(finding.escaped, isTrue);
    expect(finding.detail, contains('疑似 TUN 路由覆盖丢失'));
    expect(finding.detail, contains('192.0.2.20'));
  });

  test('healthy sample is explicitly not proof of every route', () {
    final finding = inspectWindowsTunFakeIpRoute(
      '$_physical$_tunLocal$_tunCoverage',
    );
    expect(finding.escaped, isFalse);
    expect(finding.detail, contains('不代表全部路由完整'));
  });

  test('unknown or customized TUN route never claims route loss', () {
    expect(inspectWindowsTunFakeIpRoute('').escaped, isNull);
    expect(inspectWindowsTunFakeIpRoute(_physical).escaped, isNull);
  });

  test('a more specific route overrides a lower metric broad route', () {
    final finding = inspectWindowsTunFakeIpRoute(
      '$_physical$_tunLocal'
      '196.0.0.0 252.0.0.0 On-link 198.18.0.1 10\n'
      '198.18.0.0 255.255.0.0 192.0.2.1 192.0.2.20 300\n',
    );
    expect(finding.escaped, isTrue);
    expect(finding.detail, contains('（/16）'));
  });

  test('a lower metric wins between equal-length routes', () {
    final finding = inspectWindowsTunFakeIpRoute(
      '$_physical$_tunLocal'
      '196.0.0.0 252.0.0.0 On-link 198.18.0.1 300\n'
      '196.0.0.0 252.0.0.0 192.0.2.1 192.0.2.20 400\n',
    );
    expect(finding.escaped, isFalse);
    expect(finding.detail, contains('（/6）'));
  });
}
