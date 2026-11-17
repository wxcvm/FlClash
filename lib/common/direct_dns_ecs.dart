import 'dart:io';

/// Mihomo supports ECS as a DNS-upstream URL option: #ecs=address/prefix.
/// Never guess a client subnet or alter unrelated DNS options.
bool validEcsSubnet(String value) {
  final parts = value.split('/');
  if (parts.length != 2) return false;
  final ip = InternetAddress.tryParse(parts.first);
  final bits = int.tryParse(parts.last);
  if (ip == null || bits == null) return false;
  final maxBits = ip.type == InternetAddressType.IPv4 ? 32 : 128;
  return bits >= 0 && bits <= maxBits;
}

bool _isEligible(String entry) {
  final source = entry.split('#').first.trim().toLowerCase();
  if (source.isEmpty ||
      source == 'system' ||
      source == 'dhcp' ||
      source.startsWith('dhcp://') ||
      source.startsWith('rcode://')) {
    return false;
  }
  return true;
}

bool hasDirectDnsEcsTargets(Iterable<String> entries) =>
    entries.any(_isEligible);

String? _ecsOf(String entry) {
  final index = entry.indexOf('#');
  if (index < 0) return null;
  for (final part in entry.substring(index + 1).split('&')) {
    if (part.startsWith('ecs=')) return part.substring(4);
  }
  return null;
}

/// Returns null when ECS is not set consistently on every eligible resolver.
String? sharedDirectDnsEcs(Iterable<String> entries) {
  String? shared;
  var found = false;
  for (final entry in entries.where(_isEligible)) {
    final ecs = _ecsOf(entry);
    if (ecs == null || !validEcsSubnet(ecs)) return null;
    if (found && shared != ecs) return null;
    shared = ecs;
    found = true;
  }
  return found ? shared : null;
}

/// Apply or remove ECS for eligible direct resolvers only. 'system' / DHCP
/// must remain untouched, and existing #proxy, h3, etc. are preserved.
List<String> withDirectDnsEcs(List<String> entries, String subnet) {
  final ecs = subnet.trim();
  if (ecs.isNotEmpty && !validEcsSubnet(ecs)) {
    throw const FormatException('Invalid ECS client subnet');
  }
  if (ecs.isNotEmpty && !hasDirectDnsEcsTargets(entries)) {
    throw const FormatException('No ECS-compatible direct DNS resolver');
  }
  return [
    for (final entry in entries)
      if (!_isEligible(entry)) entry else _withEcs(entry, ecs),
  ];
}

String _withEcs(String entry, String ecs) {
  final index = entry.indexOf('#');
  final upstream = index < 0 ? entry : entry.substring(0, index);
  final original = index < 0 ? '' : entry.substring(index + 1);
  final options = original.isEmpty ? <String>[] : original.split('&');
  final filtered = options
      .where((option) => !option.startsWith('ecs='))
      .toList();
  if (ecs.isNotEmpty) filtered.add('ecs=$ecs');
  return filtered.isEmpty ? upstream : '$upstream#${filtered.join('&')}';
}
