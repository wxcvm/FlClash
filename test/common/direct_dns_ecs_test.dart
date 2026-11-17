import 'package:fl_clash/common/direct_dns_ecs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves DNS flags while applying direct-only ECS', () {
    expect(
      withDirectDnsEcs([
        'system',
        'dhcp://system',
        'https://dns.example/dns-query#proxy&h3=true',
        'tls://1.1.1.1#ecs=1.2.3.0/24&skip-cert-verify=false',
      ], '203.0.113.0/24'),
      [
        'system',
        'dhcp://system',
        'https://dns.example/dns-query#proxy&h3=true&ecs=203.0.113.0/24',
        'tls://1.1.1.1#skip-cert-verify=false&ecs=203.0.113.0/24',
      ],
    );
  });

  test('clearing ECS leaves all unrelated upstream parameters intact', () {
    expect(
      withDirectDnsEcs([
        'https://dns.example/dns-query#proxy&ecs=203.0.113.0/24&h3=true',
        '223.5.5.5#ecs=198.51.100.0/24',
      ], ''),
      ['https://dns.example/dns-query#proxy&h3=true', '223.5.5.5'],
    );
  });

  test('returns shared ECS only if all eligible entries agree', () {
    expect(
      sharedDirectDnsEcs([
        'system',
        'https://dns.example/dns-query#ecs=203.0.113.0/24',
        '223.5.5.5#ecs=203.0.113.0/24',
      ]),
      '203.0.113.0/24',
    );
    expect(
      sharedDirectDnsEcs([
        'https://dns.example/dns-query#ecs=203.0.113.0/24',
        '223.5.5.5',
      ]),
      isNull,
    );
  });

  test('validates both IPv4 and IPv6 subnet lengths', () {
    expect(validEcsSubnet('203.0.113.0/24'), isTrue);
    expect(validEcsSubnet('2001:db8::/56'), isTrue);
    expect(validEcsSubnet('203.0.113.0/33'), isFalse);
    expect(validEcsSubnet('2001:db8::/129'), isFalse);
    expect(validEcsSubnet('hostname/24'), isFalse);
  });

  test('does not pretend ECS can be configured on system-only DNS', () {
    expect(
      () => withDirectDnsEcs(['system', 'dhcp://system'], '203.0.113.0/24'),
      throwsFormatException,
    );
    expect(withDirectDnsEcs(['system'], ''), ['system']);
  });
}
