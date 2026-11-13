import 'dart:io';

/// Converts a supported Clash proxy into a sing-box outbound.
/// Unknown options are rejected rather than silently changing the connection.
Map<String, dynamic> convertClashOutbound(Map<String, dynamic> proxy) {
  final type = proxy['type'];
  final name = proxy['name'];
  final server = proxy['server'];
  final port = proxy['port'];
  if (name is! String ||
      name.isEmpty ||
      server is! String ||
      server.isEmpty ||
      port is! int ||
      port < 1 ||
      port > 65535) {
    throw const FormatException('Invalid proxy endpoint');
  }
  final result = <String, dynamic>{
    'tag': name,
    'server': server,
    'server_port': port,
  };
  final allowed = <String>{'name', 'type', 'server', 'port'};
  String requiredString(String key) {
    final value = proxy[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing proxy field: $key');
    }
    return value;
  }

  switch (type) {
    case 'ss':
      allowed.addAll(['cipher', 'password']);
      result.addAll({
        'type': 'shadowsocks',
        'method': requiredString('cipher'),
        'password': requiredString('password'),
      });
    case 'socks5':
    case 'http':
      allowed.addAll(['username', 'password']);
      result['type'] = type == 'socks5' ? 'socks' : 'http';
      if (type == 'socks5') result['version'] = '5';
      for (final key in ['username', 'password']) {
        if (proxy.containsKey(key)) result[key] = requiredString(key);
      }
    case 'trojan':
    case 'hysteria2':
    case 'anytls':
      allowed.addAll(['password', 'sni', 'skip-cert-verify']);
      result.addAll({
        'type': type,
        'password': requiredString('password'),
        'tls': {
          'enabled': true,
          'server_name': requiredString('sni'),
          if (proxy.containsKey('skip-cert-verify'))
            'insecure': proxy['skip-cert-verify'],
        },
      });
      if (proxy.containsKey('skip-cert-verify') &&
          proxy['skip-cert-verify'] is! bool) {
        throw const FormatException('Invalid TLS verification option');
      }
    case 'vless':
      allowed.addAll([
        'uuid',
        'flow',
        'tls',
        'servername',
        'reality-opts',
        'client-fingerprint',
        'network',
      ]);
      result.addAll({'type': 'vless', 'uuid': requiredString('uuid')});
      if (proxy.containsKey('flow')) {
        result['flow'] = requiredString('flow');
      }
      if (proxy.containsKey('network') && proxy['network'] != 'tcp') {
        throw const FormatException('Unsupported VLESS transport');
      }
      if (proxy['tls'] != true) {
        throw const FormatException('VLESS conversion requires TLS');
      }
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': requiredString('servername'),
      };
      if (proxy.containsKey('client-fingerprint')) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': requiredString('client-fingerprint'),
        };
      }
      if (proxy.containsKey('reality-opts')) {
        final reality = proxy['reality-opts'];
        if (reality is! Map ||
            reality.keys.any(
              (key) => key != 'public-key' && key != 'short-id',
            ) ||
            reality['public-key'] is! String ||
            reality['short-id'] is! String ||
            !tls.containsKey('utls')) {
          throw const FormatException('Unsupported REALITY options');
        }
        tls['reality'] = {
          'enabled': true,
          'public_key': reality['public-key'],
          'short_id': reality['short-id'],
        };
      }
      result['tls'] = tls;
    default:
      throw const FormatException('Unsupported proxy protocol');
  }
  if (proxy.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unsupported proxy options');
  }
  return result;
}

/// Converts static selectors without changing their selected member.
/// Dynamic providers and health-check groups need separate conversion.
Map<String, dynamic> convertClashSelector(
  Map<String, dynamic> group,
  Set<String> knownTags, {
  String? selected,
}) {
  final name = group['name'];
  final members = group['proxies'];
  if (group['type'] != 'select' ||
      name is! String ||
      name.isEmpty ||
      members is! List ||
      members.isEmpty ||
      members.any((member) => member is! String || !knownTags.contains(member)) ||
      group.keys.any(
        (key) => !const {'name', 'type', 'proxies'}.contains(key),
      )) {
    throw const FormatException('Unsupported proxy group');
  }
  if (selected != null && !members.contains(selected)) {
    throw const FormatException('Selected proxy is not in group');
  }
  return {
    'type': 'selector',
    'tag': name,
    'outbounds': List<String>.from(members),
    if (selected != null) 'default': selected,
  };
}

/// Converts ordered domain rules and the terminal MATCH into a route fragment.
/// The caller must supply the remaining DNS and inbound configuration.
Map<String, dynamic> convertClashDomainRoutes(
  List<String> rules,
  Set<String> knownTags,
) {
  final converted = <Map<String, dynamic>>[];
  String? fallback;
  for (final rule in rules) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (fallback != null || parts.length < 2) {
      throw const FormatException('Invalid rule order');
    }
    final target = parts.last;
    if (!knownTags.contains(target)) {
      throw const FormatException('Unknown route target');
    }
    if (parts.first == 'MATCH' && parts.length == 2) {
      fallback = target;
      continue;
    }
    if (parts.length != 3 || parts[1].isEmpty) {
      throw const FormatException('Unsupported route rule');
    }
    final field = switch (parts.first) {
      'DOMAIN' => 'domain',
      'DOMAIN-SUFFIX' => 'domain_suffix',
      'DOMAIN-KEYWORD' => 'domain_keyword',
      _ => throw const FormatException('Unsupported route rule'),
    };
    converted.add({
      field: [parts[1]],
      'action': 'route',
      'outbound': target,
    });
  }
  if (fallback == null) {
    throw const FormatException('Missing terminal MATCH rule');
  }
  return {'rules': converted, 'final': fallback};
}

/// Assembles the outbound and route graph from a static Clash profile.
/// DNS and inbound settings remain the responsibility of the platform adapter.
Map<String, dynamic> convertClashRoutingGraph(
  Map<String, dynamic> profile, {
  Map<String, String> selected = const {},
}) {
  final proxies = profile['proxies'];
  final groups = profile['proxy-groups'];
  final rules = profile['rules'];
  if (proxies is! List ||
      groups is! List ||
      rules is! List ||
      rules.any((rule) => rule is! String)) {
    throw const FormatException('Invalid static Clash profile');
  }
  if (profile.containsKey('proxy-providers') ||
      profile.containsKey('rule-providers')) {
    throw const FormatException('Dynamic providers require conversion');
  }
  final tags = <String>{'DIRECT'};
  final outbounds = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': 'DIRECT'},
  ];
  for (final proxy in proxies) {
    if (proxy is! Map) {
      throw const FormatException('Invalid proxy');
    }
    final outbound = convertClashOutbound(Map<String, dynamic>.from(proxy));
    if (!tags.add(outbound['tag'] as String)) {
      throw const FormatException('Duplicate outbound tag');
    }
    outbounds.add(outbound);
  }
  final byName = <String, Map<String, dynamic>>{};
  for (final group in groups) {
    if (group is! Map || group['name'] is! String) {
      throw const FormatException('Invalid proxy group');
    }
    final name = group['name'] as String;
    if (!tags.add(name)) {
      throw const FormatException('Duplicate group tag');
    }
    byName[name] = Map<String, dynamic>.from(group);
  }
  final visiting = <String>{};
  final visited = <String>{};
  void visit(String name) {
    if (visited.contains(name)) return;
    if (!visiting.add(name)) {
      throw const FormatException('Cyclic proxy groups');
    }
    final group = byName[name]!;
    final outbound = convertClashSelector(
      group,
      tags,
      selected: selected[name],
    );
    for (final member in outbound['outbounds'] as List<String>) {
      if (byName.containsKey(member)) visit(member);
    }
    visiting.remove(name);
    visited.add(name);
    outbounds.add(outbound);
  }

  for (final name in byName.keys) {
    visit(name);
  }
  return {
    'outbounds': outbounds,
    'route': convertClashDomainRoutes(List<String>.from(rules), tags),
  };
}

/// Converts a single explicitly configured resolver without changing its host
/// or DoH path. Multiple resolvers and Fake-IP need their own policy mapping.
Map<String, dynamic> convertClashDns(Map<String, dynamic> dns) {
  const supported = {
    'enable',
    'enhanced-mode',
    'nameserver',
    'default-nameserver',
  };
  final servers = dns['nameserver'];
  if (dns['enable'] != true ||
      dns['enhanced-mode'] != 'redir-host' ||
      dns.keys.any((key) => !supported.contains(key)) ||
      servers is! List ||
      servers.length != 1 ||
      servers.single is! String) {
    throw const FormatException('Unsupported DNS policy');
  }
  final address = servers.single as String;
  final bootstrap = dns['default-nameserver'];
  final entries = <Map<String, dynamic>>[];
  if (bootstrap != null) {
    if (bootstrap is! List ||
        bootstrap.length != 1 ||
        bootstrap.single is! String ||
        InternetAddress.tryParse(bootstrap.single as String) == null) {
      throw const FormatException('Unsupported DNS bootstrap');
    }
    entries.add({
      'type': 'udp',
      'tag': 'bootstrap',
      'server': bootstrap.single,
    });
  }
  if (InternetAddress.tryParse(address) != null) {
    entries.add({'type': 'udp', 'tag': 'resolver', 'server': address});
  } else {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (InternetAddress.tryParse(uri.host) == null && bootstrap == null)) {
      throw const FormatException('Unsupported encrypted DNS resolver');
    }
    entries.add({
      'type': 'https',
      'tag': 'resolver',
      'server': uri.host,
      'server_port': uri.port,
      'path': uri.path.isEmpty ? '/dns-query' : uri.path,
      if (InternetAddress.tryParse(uri.host) == null)
        'domain_resolver': 'bootstrap',
    });
  }
  return {'servers': entries, 'final': 'resolver'};
}

/// Builds a candidate native configuration for an explicitly supported profile.
/// Platform callers must validate it with the installed core before handoff.
Map<String, dynamic> buildClashNativeConfig(
  Map<String, dynamic> profile, {
  required List<Map<String, dynamic>> inbounds,
  Map<String, String> selected = const {},
}) {
  const supported = {'proxies', 'proxy-groups', 'rules', 'dns', 'mode'};
  if (profile.keys.any((key) => !supported.contains(key)) ||
      (profile.containsKey('mode') && profile['mode'] != 'rule') ||
      inbounds.isEmpty ||
      profile['dns'] is! Map) {
    throw const FormatException('Unsupported profile settings');
  }
  final graph = convertClashRoutingGraph(profile, selected: selected);
  final dns = convertClashDns(Map<String, dynamic>.from(profile['dns'] as Map));
  final route = graph['route'] as Map<String, dynamic>;
  return {
    'dns': dns,
    'inbounds': inbounds,
    'outbounds': graph['outbounds'],
    'route': {
      ...route,
      'auto_detect_interface': true,
      'default_domain_resolver': 'resolver',
      'rules': [
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        ...(route['rules'] as List),
      ],
    },
  };
}
