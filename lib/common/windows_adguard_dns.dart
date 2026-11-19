import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// The resolver remains owned by Windows. AdGuard DNS protection may intercept
/// this path without FlClash reading or storing a private DNS URL.
const windowsSystemResolver = 'system://';

const _systemDnsMarkerKeys = {
  DnsOverrideKey.nameserver,
  DnsOverrideKey.proxyServerNameserver,
  DnsOverrideKey.directNameserver,
};

/// An in-memory marker for the profile builder; the stored patch is untouched.
PatchClashConfig withWindowsSystemDns(PatchClashConfig patch) => patch.copyWith(
  dns: patch.dns.copyWith(
    nameserver: const [windowsSystemResolver],
    proxyServerNameserver: const [windowsSystemResolver],
    directNameserver: const [windowsSystemResolver],
  ),
  dnsOverrideKeys: {...patch.dnsOverrideKeys, ..._systemDnsMarkerKeys},
);

bool followsWindowsSystemDns(PatchClashConfig patch) =>
    patch.dnsOverrideKeys.containsAll(_systemDnsMarkerKeys) &&
    _isSystemOnly(patch.dns.nameserver) &&
    _isSystemOnly(patch.dns.proxyServerNameserver) &&
    _isSystemOnly(patch.dns.directNameserver);

bool _isSystemOnly(List<String> servers) =>
    servers.length == 1 && servers.single == windowsSystemResolver;

/// Apply only after the subscription and per-profile DNS overlays are merged.
/// Keep policy selectors (including rule sets) and Fake-IP settings intact,
/// but route every DNS upstream through the OS rather than competing with the
/// DNS provider chosen in AdGuard for Windows.
Map<String, dynamic> applyWindowsSystemDns(Map<String, dynamic> dns) {
  final result = Map<String, dynamic>.from(dns);
  result['enable'] = true;
  result['nameserver'] = [windowsSystemResolver];
  result['proxy-server-nameserver'] = [windowsSystemResolver];
  result['direct-nameserver'] = [windowsSystemResolver];
  result['fallback'] = <String>[];

  for (final key in const [
    'nameserver-policy',
    'proxy-server-nameserver-policy',
  ]) {
    if (result[key] case final Map policy) {
      result[key] = {
        for (final entry in policy.entries) entry.key: [windowsSystemResolver],
      };
    }
  }
  return result;
}
