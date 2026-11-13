import 'dart:io';

// A fully qualified DNS name may end in a root dot. Fake-IP filters use
// the ordinary hostname form, so match both spellings with one exception.
String _resolverHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host.endsWith('.') ? host.substring(0, host.length - 1) : host;
}

/// A Fake-IP blacklist entry is a hostname, not an encrypted DNS URL.
/// Only normalize explicitly entered URLs; preserve wildcard and rule syntax.
List<String> normalizeFakeIpBlacklist(List<String> entries) {
  final result = <String>{};
  for (final entry in entries) {
    final value = entry.trim();
    final uri = Uri.tryParse(value);
    if (uri != null &&
        const {'https', 'h3', 'tls', 'quic'}.contains(uri.scheme) &&
        uri.hasAuthority &&
        _resolverHost(uri).isNotEmpty &&
        InternetAddress.tryParse(_resolverHost(uri)) == null) {
      result.add(_resolverHost(uri));
    } else {
      result.add(value);
    }
  }
  return result.toList();
}

/// Keep encrypted resolver hostnames reachable without assigning a synthetic IP
/// to the resolver itself. Only explicit upstreams in the effective profile
/// are considered; the original subscription and DNS route policy stay intact.
List<String> encryptedDnsEndpointHosts(Map<String, dynamic> dns) {
  final hosts = <String>{};
  void add(Object? value) {
    if (value is List) {
      for (final item in value) {
        add(item);
      }
      return;
    }
    if (value is! String) return;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !const {'https', 'h3', 'tls', 'quic'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        _resolverHost(uri).isEmpty ||
        InternetAddress.tryParse(_resolverHost(uri)) != null) {
      return;
    }
    hosts.add(_resolverHost(uri));
  }

  for (final key in const [
    'default-nameserver',
    'nameserver',
    'fallback',
    'proxy-server-nameserver',
    'direct-nameserver',
  ]) {
    add(dns[key]);
  }
  for (final key in const [
    'nameserver-policy',
    'proxy-server-nameserver-policy',
  ]) {
    final policy = dns[key];
    if (policy is Map) {
      for (final value in policy.values) {
        add(value);
      }
    }
  }
  return hosts.toList();
}

/// Only blacklist mode has unambiguous exclusion semantics. An explicit
/// whitelist/rule-mode configuration must not be rewritten.
void applyEncryptedDnsFakeIpCompatibility(Map<String, dynamic> dns) {
  if (dns['enable'] != true ||
      dns['enhanced-mode'] != 'fake-ip' ||
      (dns['fake-ip-filter-mode'] ?? 'blacklist') != 'blacklist') {
    return;
  }
  final entries = dns['fake-ip-filter'];
  if (entries != null &&
      (entries is! List || !entries.every((entry) => entry is String))) {
    return;
  }
  final hosts = encryptedDnsEndpointHosts(dns);
  final normalized = normalizeFakeIpBlacklist(
    entries is List ? entries.cast<String>() : const [],
  );
  if (entries != null || hosts.isNotEmpty) {
    dns['fake-ip-filter'] = {...normalized, ...hosts}.toList();
  }
}
