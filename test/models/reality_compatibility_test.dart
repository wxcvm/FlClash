import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('REALITY ML-KEM option', () {
    final proxy = CustomProxy.fromDefinition({
      'name': 'reality',
      'type': 'vless',
      'server': 'example.com',
      'port': 443,
      'uuid': 'test',
      'tls': true,
      'client-fingerprint': 'chrome',
      'reality-opts': {'public-key': 'pk'},
    });
    expect(proxy.options, contains(ProxyField.realityMlkem768));
    expect(proxy.valueOf(ProxyField.realityMlkem768), isNull);

    final enabled = proxy.withField(ProxyField.realityMlkem768, true);
    final opts = enabled.definition['reality-opts'] as Map;
    expect(opts['public-key'], 'pk');
    expect(opts['support-x25519mlkem768'], isTrue);
    expect(proxy.valueOf(ProxyField.realityMlkem768), isNull);

    final disabled = enabled.withField(ProxyField.realityMlkem768, false);
    expect(disabled.valueOf(ProxyField.realityMlkem768), isFalse);
  });
}
