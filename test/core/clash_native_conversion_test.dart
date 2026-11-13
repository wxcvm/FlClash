import 'package:fl_clash/core/clash_native_conversion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final endpoint = <String, dynamic>{
    'name': 'node',
    'server': 'example.com',
    'port': 443,
  };

  test('converts Shadowsocks credentials', () {
    expect(
      convertClashOutbound({
        ...endpoint,
        'type': 'ss',
        'cipher': 'aes-128-gcm',
        'password': 'secret',
      }),
      {
        'tag': 'node',
        'server': 'example.com',
        'server_port': 443,
        'type': 'shadowsocks',
        'method': 'aes-128-gcm',
        'password': 'secret',
      },
    );
  });

  test('preserves VLESS Vision and REALITY settings', () {
    final result = convertClashOutbound({
      ...endpoint,
      'type': 'vless',
      'uuid': '00000000-0000-4000-8000-000000000001',
      'flow': 'xtls-rprx-vision',
      'tls': true,
      'servername': 'example.com',
      'client-fingerprint': 'chrome',
      'reality-opts': {'public-key': 'key', 'short-id': 'abcd'},
    });
    expect(result['flow'], 'xtls-rprx-vision');
    expect(result['tls'], {
      'enabled': true,
      'server_name': 'example.com',
      'utls': {'enabled': true, 'fingerprint': 'chrome'},
      'reality': {
        'enabled': true,
        'public_key': 'key',
        'short_id': 'abcd',
      },
    });
  });

  test('rejects options that cannot be preserved', () {
    expect(
      () => convertClashOutbound({
        ...endpoint,
        'type': 'ss',
        'cipher': 'aes-128-gcm',
        'password': 'secret',
        'plugin': 'obfs',
      }),
      throwsFormatException,
    );
  });

  test('rejects unsupported protocol', () {
    expect(
      () => convertClashOutbound({...endpoint, 'type': 'unknown'}),
      throwsFormatException,
    );
  });
  test('preserves selector order and selected member', () {
    expect(
      convertClashSelector({
        'name': 'Proxy',
        'type': 'select',
        'proxies': ['a', 'b'],
      }, {'a', 'b'}, selected: 'b'),
      {
        'type': 'selector',
        'tag': 'Proxy',
        'outbounds': ['a', 'b'],
        'default': 'b',
      },
    );
  });

  test('preserves ordered domain rules and final route', () {
    expect(
      convertClashDomainRoutes([
        'DOMAIN,example.com,DIRECT',
        'DOMAIN-SUFFIX,example.org,Proxy',
        'MATCH,Proxy',
      ], {'DIRECT', 'Proxy'}),
      {
        'rules': [
          {
            'domain': ['example.com'],
            'action': 'route',
            'outbound': 'DIRECT',
          },
          {
            'domain_suffix': ['example.org'],
            'action': 'route',
            'outbound': 'Proxy',
          },
        ],
        'final': 'Proxy',
      },
    );
  });

  test('rejects unsupported rule instead of dropping it', () {
    expect(
      () => convertClashDomainRoutes([
        'GEOIP,CN,DIRECT',
        'MATCH,Proxy',
      ], {'DIRECT', 'Proxy'}),
      throwsFormatException,
    );
  });

  test('converts basic TLS password protocols', () {
    for (final type in ['trojan', 'hysteria2', 'anytls']) {
      final result = convertClashOutbound({
        ...endpoint,
        'type': type,
        'password': 'secret',
        'sni': 'example.com',
        'skip-cert-verify': false,
      });
      expect(result['type'], type);
      expect(result['tls'], {
        'enabled': true,
        'server_name': 'example.com',
        'insecure': false,
      });
    }
  });
}
