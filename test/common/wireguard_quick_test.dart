import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/wireguard_quick.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

const _privateKey = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=';
const _publicKey = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=';

const _basic =
    '''
[Interface]
PrivateKey = $_privateKey
Address = 10.0.0.2/32
MTU = 1280

[Peer]
PublicKey = $_publicKey
AllowedIPs = 0.0.0.0/0
Endpoint = wg.example.com:51820
PersistentKeepalive = 25
''';

void main() {
  test('converts one full-tunnel WireGuard peer to Mihomo YAML', () {
    final bytes = Uint8List.fromList(utf8.encode(_basic));
    final converted = convertWireGuardQuickFile(bytes, fileName: 'Home.conf');
    final data = loadYaml(utf8.decode(converted)) as Map;
    final proxy = (data['proxies'] as List).single as Map;

    expect(proxy['type'], 'wireguard');
    expect(proxy['name'], 'Home');
    expect(proxy['server'], 'wg.example.com');
    expect(proxy['port'], 51820);
    expect(proxy['ip'], '10.0.0.2/32');
    expect(proxy['private-key'], _privateKey);
    expect(proxy['public-key'], _publicKey);
    expect(proxy['persistent-keepalive'], 25);
    expect(proxy['mtu'], 1280);
    expect(proxy['udp'], true);
  });

  test('preserves IPv6 endpoint and both address families', () {
    const conf =
        '''
# comment
[Interface]
PrivateKey = $_privateKey
Address = 10.0.0.2/32, 2001:db8::2/128
DNS = 1.1.1.1, 2606:4700:4700::1111
[Peer]
PublicKey = $_publicKey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [2001:db8::1]:51820
''';
    final proxy = parseWireGuardQuick(
      '\uFEFF${conf.replaceAll('\n', '\r\n')}',
      fileName: 'ipv6.conf',
    )!;
    expect(proxy['server'], '2001:db8::1');
    expect(proxy['ipv6'], '2001:db8::2/128');
    expect(proxy['dns'], ['1.1.1.1', '2606:4700:4700::1111']);
    expect(proxy['remote-dns-resolve'], true);
  });

  test('does not change existing YAML and other imported files', () {
    for (final text in [
      'proxies:\n  - {name: TEST, type: direct}\n',
      '[Unrelated]\nValue = ok\n',
    ]) {
      final bytes = Uint8List.fromList(utf8.encode(text));
      expect(
        identical(
          convertWireGuardQuickFile(bytes, fileName: 'other.conf'),
          bytes,
        ),
        isTrue,
      );
    }
  });

  test('supports repeated Address and AllowedIPs directives', () {
    const conf =
        '''
[Interface]
PrivateKey = $_privateKey
Address = 10.0.0.2/32
Address = 2001:db8::2/128
[Peer]
PublicKey = $_publicKey
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = wg.example.com:51820
''';
    final proxy = parseWireGuardQuick(conf, fileName: 'wg0.conf')!;
    expect(proxy['ip'], '10.0.0.2/32');
    expect(proxy['ipv6'], '2001:db8::2/128');
  });

  test('rejects multiple peers rather than silently dropping one', () {
    const conf =
        '''
$_basic
[Peer]
PublicKey = $_publicKey
AllowedIPs = 0.0.0.0/0
Endpoint = other.example.com:51820
''';
    expect(
      () => parseWireGuardQuick(conf, fileName: 'wg.conf'),
      throwsA(isA<WireGuardQuickImportException>()),
    );
  });

  test('rejects split routes and unsupported wg-quick scripts', () {
    for (final conf in [
      _basic.replaceFirst('0.0.0.0/0', '192.168.0.0/16'),
      _basic.replaceFirst('[Peer]', 'PostUp = iptables -A OUTPUT\n[Peer]'),
      _basic.replaceFirst('AllowedIPs = 0.0.0.0/0', ''),
    ]) {
      expect(
        () => parseWireGuardQuick(conf, fileName: 'wg.conf'),
        throwsA(isA<WireGuardQuickImportException>()),
      );
    }
  });

  test('rejects invalid secrets without putting them into error messages', () {
    const secret = 'INVALID-PRIVATE-KEY-VALUE';
    final conf = _basic.replaceFirst(_privateKey, secret);
    try {
      parseWireGuardQuick(conf, fileName: 'wg.conf');
      fail('Malformed private key was accepted');
    } on WireGuardQuickImportException catch (error) {
      expect(error.toString(), isNot(contains(secret)));
    }
  });

  test('rejects malformed and ambiguous endpoints', () {
    for (final endpoint in [
      'wg.example.com',
      'wg.example.com:65536',
      '2001:db8::1:51820',
      '[bad:ipv6]:51820',
    ]) {
      expect(
        () => parseWireGuardQuick(
          _basic.replaceFirst('wg.example.com:51820', endpoint),
          fileName: 'wg.conf',
        ),
        throwsA(isA<WireGuardQuickImportException>()),
      );
    }
  });

  test('rejects missing sections and repeated options', () {
    for (final conf in [
      '[Interface]\nPrivateKey = $_privateKey\n',
      _basic.replaceFirst('MTU = 1280', 'MTU = 1280\nMTU = 1200'),
    ]) {
      expect(
        () => parseWireGuardQuick(conf, fileName: 'wg.conf'),
        throwsA(isA<WireGuardQuickImportException>()),
      );
    }
  });
}
