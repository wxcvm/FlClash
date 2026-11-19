import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/windows_adguard_dns.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Windows DNS marker never rewrites the stored DNS configuration', () {
    const original = PatchClashConfig(
      dns: Dns(
        nameserver: ['https://private.example/secret-path'],
        proxyServerNameserver: ['9.9.9.9'],
        directNameserver: ['223.5.5.5'],
      ),
      dnsOverrideKeys: {DnsOverrideKey.nameserver},
    );
    final marked = withWindowsSystemDns(original);

    expect(original.dns.nameserver, ['https://private.example/secret-path']);
    expect(original.dns.proxyServerNameserver, ['9.9.9.9']);
    expect(followsWindowsSystemDns(original), isFalse);
    expect(followsWindowsSystemDns(marked), isTrue);
    expect(marked.dnsOverrideKeys, containsAll([
      DnsOverrideKey.nameserver,
      DnsOverrideKey.proxyServerNameserver,
      DnsOverrideKey.directNameserver,
    ]));
    expect(marked.dns.nameserver, [windowsSystemResolver]);
  });

  test('effective DNS follows OS for main, direct, node and policy resolvers', () {
    final profile = <String, dynamic>{
      'enable': true,
      'enhanced-mode': 'fake-ip',
      'fake-ip-filter': ['*.lan'],
      'nameserver': ['https://private.example/secret-path'],
      'fallback': ['tls://1.1.1.1'],
      'proxy-server-nameserver': ['8.8.8.8'],
      'direct-nameserver': ['223.5.5.5'],
      'nameserver-policy': {
        '+.lan': ['192.0.2.53'],
        'rule-set:cn': ['https://example.net/dns-query'],
      },
      'proxy-server-nameserver-policy': {
        'node.example': ['9.9.9.9'],
      },
    };
    final effective = applyWindowsSystemDns(profile);

    expect(effective['nameserver'], [windowsSystemResolver]);
    expect(effective['proxy-server-nameserver'], [windowsSystemResolver]);
    expect(effective['direct-nameserver'], [windowsSystemResolver]);
    expect(effective['fallback'], isEmpty);
    expect(effective['nameserver-policy'], {
      '+.lan': [windowsSystemResolver],
      'rule-set:cn': [windowsSystemResolver],
    });
    expect(effective['proxy-server-nameserver-policy'], {
      'node.example': [windowsSystemResolver],
    });
    expect(effective['enhanced-mode'], 'fake-ip');
    expect(effective['fake-ip-filter'], ['*.lan']);
    expect(profile['nameserver'], ['https://private.example/secret-path']);
    expect(profile['nameserver-policy'], {
      '+.lan': ['192.0.2.53'],
      'rule-set:cn': ['https://example.net/dns-query'],
    });
  });

  test('real profile uses system resolver only when in-memory marker is set', () async {
    Future<YamlMap> generate(PatchClashConfig patch) async {
      final result = await makeRealProfileTask(
        MakeRealProfileState(
          profilesPath: '/profiles',
          profileId: 1,
          rawConfig: {
            'dns': {
              'enable': true,
              'enhanced-mode': 'fake-ip',
              'nameserver': ['https://private.example/secret-path'],
              'fallback': ['tls://1.1.1.1'],
              'nameserver-policy': {
                '+.example.com': ['https://dns.example/dns-query'],
              },
            },
          },
          realPatchConfig: patch,
          overrides: const ProfileOverrides(),
          keepEmptyDnsOverrides: true,
          appendSystemDns: false,
          proxyGroups: const [],
          rules: const [],
          addedRules: const [],
          defaultUA: 'FlClash-test',
        ),
      );
      return (loadYaml(result.yaml) as YamlMap)['dns'] as YamlMap;
    }

    const patch = PatchClashConfig();
    final normal = await generate(patch);
    expect(normal['nameserver'], ['https://private.example/secret-path']);
    expect(normal['fallback'], ['tls://1.1.1.1']);

    final enabled = await generate(withWindowsSystemDns(patch));
    expect(enabled['nameserver'], [windowsSystemResolver]);
    expect(enabled['fallback'], isEmpty);
    expect(enabled['nameserver-policy'], {
      '+.example.com': [windowsSystemResolver],
    });
    expect(enabled['enhanced-mode'], 'fake-ip');
  });
}
