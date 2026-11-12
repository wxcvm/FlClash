import 'package:fl_clash/providers/download_speed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subscription metadata names are not speed candidates', () {
    for (final name in ['剩余流量：959.93 GB', '套餐到期: 长期有效', '  订阅到期：2027-01-01']) {
      expect(isSubscriptionInfoProxyName(name), isTrue, reason: name);
    }
    for (final name in ['日本专线-0.1倍率', '美国凤凰城', '香港剩余流量优化节点']) {
      expect(isSubscriptionInfoProxyName(name), isFalse, reason: name);
    }
  });
}
