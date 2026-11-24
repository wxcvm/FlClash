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
      'reality': {'enabled': true, 'public_key': 'key', 'short_id': 'abcd'},
    });
  });

  test('preserves VLESS WebSocket TLS with separate SNI and Host', () {
    final result = convertClashOutbound({
      ...endpoint,
      'type': 'vless',
      'uuid': '00000000-0000-4000-8000-000000000001',
      'flow': '',
      'udp': true,
      'tls': true,
      'skip-cert-verify': false,
      'servername': 'tls.example.org',
      'client-fingerprint': 'safari',
      'network': 'ws',
      'ws-opts': {
        'path': '/service/ai',
        'headers': {'Host': 'ws.example.org'},
      },
    });
    expect(result['flow'], isNull);
    expect(result['network'], isNull);
    expect(result['tls'], {
      'enabled': true,
      'server_name': 'tls.example.org',
      'insecure': false,
      'utls': {'enabled': true, 'fingerprint': 'safari'},
    });
    expect(result['transport'], {
      'type': 'ws',
      'path': '/service/ai',
      'headers': {'Host': 'ws.example.org'},
    });
  });

  test('retains VLESS UDP-disabled semantics', () {
    final result = convertClashOutbound({
      ...endpoint,
      'type': 'vless',
      'uuid': '00000000-0000-4000-8000-000000000001',
      'network': 'tcp',
      'tls': true,
      'servername': 'example.org',
      'udp': false,
    });
    expect(result['network'], 'tcp');
  });

  test('preserves explicit VLESS WebSocket early data settings', () {
    final result = convertClashOutbound({
      ...endpoint,
      'type': 'vless',
      'uuid': '00000000-0000-4000-8000-000000000001',
      'tls': true,
      'servername': 'tls.example.org',
      'network': 'ws',
      'ws-opts': {
        'path': '/service',
        'headers': {'Host': 'ws.example.org'},
        'max-early-data': 2048,
        'early-data-header-name': 'Sec-WebSocket-Protocol',
      },
    });
    expect(result['transport'], {
      'type': 'ws',
      'path': '/service',
      'headers': {'Host': 'ws.example.org'},
      'max_early_data': 2048,
      'early_data_header_name': 'Sec-WebSocket-Protocol',
    });
    expect(result['tls']['server_name'], 'tls.example.org');
  });

  test('rejects invalid or ambiguous WebSocket early data settings', () {
    for (final ws in [
      {'max-early-data': -1},
      {'max-early-data': '2048'},
      {'max-early-data': 65536},
      {'max-early-data': 2048},
      {'max-early-data': 2048, 'early-data-header-name': 42},
      {'max-early-data': 2048, 'early-data-header-name': 'Bad Header'},
    ]) {
      expect(
        () => convertClashOutbound({
          ...endpoint,
          'type': 'vless',
          'uuid': '00000000-0000-4000-8000-000000000001',
          'tls': true,
          'servername': 'tls.example.org',
          'network': 'ws',
          'ws-opts': ws,
        }),
        throwsFormatException,
      );
    }
  });

  test('rejects unsupported WebSocket options rather than discarding them', () {
    expect(
      () => convertClashOutbound({
        ...endpoint,
        'type': 'vless',
        'uuid': '00000000-0000-4000-8000-000000000001',
        'network': 'ws',
        'ws-opts': {'path': '/path', 'unsupported': true},
        'tls': true,
        'servername': 'example.org',
      }),
      throwsFormatException,
    );
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
      convertClashSelector(
        {
          'name': 'Proxy',
          'type': 'select',
          'proxies': ['a', 'b'],
        },
        {'a', 'b'},
        selected: 'b',
      ),
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
      convertClashDomainRoutes(
        [
          'DOMAIN,example.com,DIRECT',
          'DOMAIN-SUFFIX,example.org,Proxy',
          'MATCH,Proxy',
        ],
        {'DIRECT', 'Proxy'},
      ),
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
      () => convertClashDomainRoutes(
        ['GEOIP,CN,DIRECT', 'MATCH,Proxy'],
        {'DIRECT', 'Proxy'},
      ),
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
  test('does not discard Hysteria2 certificate pinning', () {
    expect(
      () => convertClashOutbound({
        ...endpoint,
        'type': 'hysteria2',
        'password': 'placeholder',
        'sni': 'example.com',
        'skip-cert-verify': true,
        'ports': '61000-62000',
        'fingerprint': 'a' * 64,
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('certificate fingerprint cannot be preserved'),
        ),
      ),
    );
  });

  test('explains unsupported Hysteria2 port hopping separately', () {
    expect(
      () => convertClashOutbound({
        ...endpoint,
        'type': 'hysteria2',
        'password': 'placeholder',
        'sni': 'example.com',
        'ports': '61000-62000',
        'mport': '61000-62000',
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('port hopping is not yet converted'),
        ),
      ),
    );
  });

  test('assembles nested groups and preserves selected member', () {
    final graph = convertClashRoutingGraph(
      {
        'proxies': [
          {
            ...endpoint,
            'type': 'ss',
            'cipher': 'aes-128-gcm',
            'password': 'secret',
          },
        ],
        'proxy-groups': [
          {
            'name': 'outer',
            'type': 'select',
            'proxies': ['inner', 'DIRECT'],
          },
          {
            'name': 'inner',
            'type': 'select',
            'proxies': ['node'],
          },
        ],
        'rules': ['MATCH,outer'],
      },
      selected: {'outer': 'inner'},
    );
    final outbounds = graph['outbounds'] as List;
    expect(outbounds.map((item) => item['tag']), [
      'DIRECT',
      'node',
      'inner',
      'outer',
    ]);
    expect(outbounds.last['default'], 'inner');
    expect(graph['route'], {'rules': [], 'final': 'outer'});
  });

  test('rejects cyclic groups', () {
    expect(
      () => convertClashRoutingGraph({
        'proxies': [],
        'proxy-groups': [
          {
            'name': 'a',
            'type': 'select',
            'proxies': ['b'],
          },
          {
            'name': 'b',
            'type': 'select',
            'proxies': ['a'],
          },
        ],
        'rules': ['MATCH,a'],
      }),
      throwsFormatException,
    );
  });
  test('preserves DoH path and explicit bootstrap', () {
    final dns = convertClashDns({
      'enable': true,
      'enhanced-mode': 'redir-host',
      'nameserver': ['https://example.com:8443/custom/dns-query'],
      'default-nameserver': ['192.0.2.53'],
    });
    expect(dns['servers'], [
      {'type': 'udp', 'tag': 'bootstrap', 'server': '192.0.2.53'},
      {
        'type': 'https',
        'tag': 'resolver',
        'server': 'example.com',
        'server_port': 8443,
        'path': '/custom/dns-query',
        'domain_resolver': 'bootstrap',
      },
    ]);
  });

  test('does not silently replace Fake-IP DNS', () {
    expect(
      () => convertClashDns({
        'enable': true,
        'enhanced-mode': 'fake-ip',
        'nameserver': ['192.0.2.53'],
      }),
      throwsFormatException,
    );
  });

  test('assembles a candidate with explicit platform inbound', () {
    final config = buildClashNativeConfig(
      {
        'proxies': [],
        'proxy-groups': [],
        'rules': ['MATCH,DIRECT'],
        'dns': {
          'enable': true,
          'enhanced-mode': 'redir-host',
          'nameserver': ['192.0.2.53'],
        },
      },
      inbounds: [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 7890},
      ],
    );
    expect(config['inbounds'], [
      {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 7890},
    ]);
    expect(config['route'], {
      'final': 'DIRECT',
      'auto_detect_interface': true,
      'default_domain_resolver': 'resolver',
      'rules': [
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
      ],
    });
  });
}
