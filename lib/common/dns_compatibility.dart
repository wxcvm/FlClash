import 'dart:io';

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
        uri.host.isNotEmpty &&
        InternetAddress.tryParse(uri.host) == null) {
      result.add(uri.host.toLowerCase());
    } else {
      result.add(value);
    }
  }
  return result.toList();
}
