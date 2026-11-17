import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/dns_compatibility.dart';
import 'package:fl_clash/common/direct_dns_ecs.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/views/config/override.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

extension on DnsOverrideKey {
  String label(AppLocalizations l) => switch (this) {
    DnsOverrideKey.enable => l.status,
    DnsOverrideKey.listen => l.listen,
    DnsOverrideKey.listenRoutingMark => l.listenRoutingMark,
    DnsOverrideKey.useHosts => l.useHosts,
    DnsOverrideKey.useSystemHosts => l.useSystemHosts,
    DnsOverrideKey.ipv6 => 'IPv6',
    DnsOverrideKey.ipv6Timeout => l.ipv6Timeout,
    DnsOverrideKey.respectRules => l.respectRules,
    DnsOverrideKey.preferH3 => 'Prefer H3',
    DnsOverrideKey.cacheAlgorithm => l.cacheAlgorithm,
    DnsOverrideKey.cacheMaxSize => l.cacheMaxSize,
    DnsOverrideKey.enhancedMode => l.dnsMode,
    DnsOverrideKey.fakeIpRange => l.fakeipRange,
    DnsOverrideKey.fakeIpRange6 => l.fakeipRange6,
    DnsOverrideKey.fakeIpFilter => l.fakeipFilter,
    DnsOverrideKey.fakeIpFilterMode => l.fakeipFilterMode,
    DnsOverrideKey.fakeIpTtl => l.fakeipTtl,
    DnsOverrideKey.defaultNameserver => '引导 DNS',
    DnsOverrideKey.nameserverPolicy => '域名解析策略',
    DnsOverrideKey.nameserver => '通用 DNS',
    DnsOverrideKey.fallback => '后备 DNS',
    DnsOverrideKey.fallbackLazyQuery => 'Fallback Lazy Query',
    DnsOverrideKey.proxyServerNameserver => '代理节点 DNS',
    DnsOverrideKey.proxyServerNameserverPolicy => '代理节点 DNS 策略',
    DnsOverrideKey.directNameserver => '直连流量 DNS',
    DnsOverrideKey.directNameserverFollowPolicy => '直连 DNS 遵循域名策略',
    DnsOverrideKey.fallbackFilterGeoip => 'GeoIP',
    DnsOverrideKey.fallbackFilterGeoipCode => 'GeoIP Code',
    DnsOverrideKey.fallbackFilterGeosite => 'GeoSite',
    DnsOverrideKey.fallbackFilterIpcidr => 'IP-CIDR',
    DnsOverrideKey.fallbackFilterDomain => l.domain,
  };

  ConfigLabel? get description => switch (this) {
    DnsOverrideKey.enable => (l) => l.statusDesc,
    DnsOverrideKey.listenRoutingMark => (l) => l.listenRoutingMarkDesc,
    DnsOverrideKey.respectRules => (l) => l.respectRulesDesc,
    DnsOverrideKey.directNameserver => (_) =>
      '直连流量专用解析器。ECS 可改善部分 CDN 的地域解析，也可能向 DNS 上游披露客户端子网；默认不启用。',
    _ => null,
  };

  String section(AppLocalizations l) => switch (this) {
    DnsOverrideKey.enable ||
    DnsOverrideKey.listen ||
    DnsOverrideKey.listenRoutingMark ||
    DnsOverrideKey.useHosts ||
    DnsOverrideKey.useSystemHosts ||
    DnsOverrideKey.ipv6 ||
    DnsOverrideKey.ipv6Timeout ||
    DnsOverrideKey.respectRules ||
    DnsOverrideKey.preferH3 ||
    DnsOverrideKey.cacheAlgorithm ||
    DnsOverrideKey.cacheMaxSize ||
    DnsOverrideKey.enhancedMode => l.options,
    DnsOverrideKey.fakeIpRange ||
    DnsOverrideKey.fakeIpRange6 ||
    DnsOverrideKey.fakeIpFilter ||
    DnsOverrideKey.fakeIpFilterMode ||
    DnsOverrideKey.fakeIpTtl => 'Fake-IP',
    DnsOverrideKey.defaultNameserver => 'DNS 引导解析',
    DnsOverrideKey.nameserverPolicy ||
    DnsOverrideKey.nameserver ||
    DnsOverrideKey.fallback ||
    DnsOverrideKey.fallbackLazyQuery => '通用解析与策略',
    DnsOverrideKey.proxyServerNameserver ||
    DnsOverrideKey.proxyServerNameserverPolicy => '代理节点解析',
    DnsOverrideKey.directNameserver ||
    DnsOverrideKey.directNameserverFollowPolicy => '直连流量解析',
    DnsOverrideKey.fallbackFilterGeoip ||
    DnsOverrideKey.fallbackFilterGeoipCode ||
    DnsOverrideKey.fallbackFilterGeosite ||
    DnsOverrideKey.fallbackFilterIpcidr ||
    DnsOverrideKey.fallbackFilterDomain => l.fallbackFilter,
  };
}

// mihomo reports `hosts` in connection metadata but rejects it as an
// enhanced-mode.
const _enhancedModes = [DnsMode.normal, DnsMode.fakeIp, DnsMode.redirHost];

String _enhancedModeValue(DnsMode mode) => switch (mode) {
  DnsMode.normal => 'normal',
  DnsMode.fakeIp => 'fake-ip',
  DnsMode.redirHost => 'redir-host',
  DnsMode.hosts => 'hosts',
};

typedef _DnsState = OverrideState<DnsOverrideKey, Dns>;

_DnsState _patchDns(PatchClashConfig config) =>
    (model: config.dns, keys: config.dnsOverrideKeys);

PatchClashConfig _setPatchDns(PatchClashConfig config, _DnsState state) =>
    config.copyWith(dns: state.model, dnsOverrideKeys: state.keys);

_DnsState _profileDns(ProfileOverrides overrides) =>
    (model: overrides.dns, keys: overrides.dnsOverrideKeys);

ProfileOverrides _setProfileDns(ProfileOverrides overrides, _DnsState state) =>
    overrides.copyWith(dns: state.model, dnsOverrideKeys: state.keys);

String _patchDnsDescription(AppLocalizations l) => l.dnsOverrideDesc;

class DnsView extends OverrideView<DnsOverrideKey, Dns> {
  /// The keys written over the DNS of every subscription and file profile.
  const DnsView({super.key})
    : super(
        spec: const _DnsOverrideSpec(
          PatchOverrideTarget(
            get: _patchDns,
            set: _setPatchDns,
            description: _patchDnsDescription,
          ),
          keys: DnsOverrideKey.normalProfileKeys,
        ),
      );

  DnsView.profile(int profileId, {super.key})
    : super(
        spec: _ProfileDnsOverrideSpec(
          ProfileOverrideTarget(
            profileId,
            get: _profileDns,
            set: _setProfileDns,
            issues: customProfileIssuesProvider(
              profileId,
            ).select((state) => state.dns),
          ),
        ),
      );
}

class _DnsOverrideSpec extends OverrideSpec<DnsOverrideKey, Dns> {
  const _DnsOverrideSpec(this.target, {this.keys});

  @override
  final OverrideTarget<DnsOverrideKey, Dns> target;

  final Set<DnsOverrideKey>? keys;

  @override
  String title(AppLocalizations l) => 'DNS';

  @override
  List<DnsOverrideKey> get values =>
      keys == null ? DnsOverrideKey.values : [...?keys];

  @override
  NullStatusIllustration get illustration => NullStatusIllustration.dns;

  @override
  Dns get defaults => defaultDns;

  @override
  String sectionOf(DnsOverrideKey key, AppLocalizations l) => key.section(l);

  @override
  String label(DnsOverrideKey key, AppLocalizations l) => key.label(l);

  @override
  ConfigLabel? description(DnsOverrideKey key) => key.description;

  @override
  OverrideField<Dns> fieldOf(DnsOverrideKey key) => switch (key) {
    DnsOverrideKey.enable => ToggleOverrideField(
      (dns) => dns.enable,
      (dns, value) => dns.copyWith(enable: value),
    ),
    DnsOverrideKey.listen => TextOverrideField(
      (dns) => dns.listen,
      (dns, value) => dns.copyWith(listen: value),
      maxLength: TextInputLimits.dnsListen,
      validator: validateListenAddress,
    ),
    DnsOverrideKey.listenRoutingMark => NumberOverrideField(
      (dns) => dns.listenRoutingMark,
      (dns, value) => dns.copyWith(listenRoutingMark: value),
    ),
    DnsOverrideKey.useHosts => ToggleOverrideField(
      (dns) => dns.useHosts,
      (dns, value) => dns.copyWith(useHosts: value),
    ),
    DnsOverrideKey.useSystemHosts => ToggleOverrideField(
      (dns) => dns.useSystemHosts,
      (dns, value) => dns.copyWith(useSystemHosts: value),
    ),
    DnsOverrideKey.ipv6 => ToggleOverrideField(
      (dns) => dns.ipv6,
      (dns, value) => dns.copyWith(ipv6: value),
    ),
    DnsOverrideKey.ipv6Timeout => NumberOverrideField(
      (dns) => dns.ipv6Timeout,
      (dns, value) => dns.copyWith(ipv6Timeout: value),
    ),
    DnsOverrideKey.respectRules => ToggleOverrideField(
      (dns) => dns.respectRules,
      (dns, value) => dns.copyWith(respectRules: value),
    ),
    DnsOverrideKey.preferH3 => ToggleOverrideField(
      (dns) => dns.preferH3,
      (dns, value) => dns.copyWith(preferH3: value),
    ),
    DnsOverrideKey.cacheAlgorithm => OptionsOverrideField(
      DnsCacheAlgorithm.values,
      (dns) => dns.cacheAlgorithm,
      (dns, value) => dns.copyWith(cacheAlgorithm: value),
    ),
    DnsOverrideKey.cacheMaxSize => NumberOverrideField(
      (dns) => dns.cacheMaxSize,
      (dns, value) => dns.copyWith(cacheMaxSize: value),
    ),
    DnsOverrideKey.enhancedMode => OptionsOverrideField(
      _enhancedModes,
      (dns) => dns.enhancedMode,
      (dns, value) => dns.copyWith(enhancedMode: value),
      labelOf: _enhancedModeValue,
    ),
    DnsOverrideKey.fakeIpRange => TextOverrideField(
      (dns) => dns.fakeIpRange,
      (dns, value) => dns.copyWith(fakeIpRange: value),
      maxLength: TextInputLimits.cidr,
      validator: validateCidr,
    ),
    DnsOverrideKey.fakeIpRange6 => TextOverrideField(
      (dns) => dns.fakeIpRange6,
      (dns, value) => dns.copyWith(fakeIpRange6: value),
      maxLength: TextInputLimits.cidr,
      validator: validateCidr,
    ),
    DnsOverrideKey.fakeIpFilter => ListOverrideField(
      (dns) => dns.fakeIpFilter,
      (dns, value) => dns.copyWith(
        fakeIpFilter: dns.fakeIpFilterMode == FakeIpFilterMode.blacklist
            ? normalizeFakeIpBlacklist(value)
            : value,
      ),
      itemMaxLength: TextInputLimits.dnsServer,
      description: (l) => l.fakeipFilterDesc,
    ),
    DnsOverrideKey.fakeIpFilterMode => OptionsOverrideField(
      FakeIpFilterMode.values,
      (dns) => dns.fakeIpFilterMode,
      (dns, value) => dns.copyWith(fakeIpFilterMode: value),
    ),
    DnsOverrideKey.fakeIpTtl => NumberOverrideField(
      (dns) => dns.fakeIpTtl,
      (dns, value) => dns.copyWith(fakeIpTtl: value),
    ),
    DnsOverrideKey.defaultNameserver => ListOverrideField(
      (dns) => dns.defaultNameserver,
      (dns, value) => dns.copyWith(defaultNameserver: value),
      itemMaxLength: TextInputLimits.dnsServer,
      description: (l) => l.defaultNameserverDesc,
    ),
    DnsOverrideKey.nameserverPolicy => _PolicyField(
      (dns) => dns.nameserverPolicy,
      (dns, value) => dns.copyWith(nameserverPolicy: value),
      description: (l) => l.nameserverPolicyDesc,
    ),
    DnsOverrideKey.nameserver => ListOverrideField(
      (dns) => dns.nameserver,
      (dns, value) => dns.copyWith(nameserver: value),
      itemMaxLength: TextInputLimits.dnsServer,
      description: (l) => l.nameserverDesc,
    ),
    DnsOverrideKey.fallback => ListOverrideField(
      (dns) => dns.fallback,
      (dns, value) => dns.copyWith(fallback: value),
      itemMaxLength: TextInputLimits.dnsServer,
      description: (l) => l.fallbackDesc,
    ),
    DnsOverrideKey.fallbackLazyQuery => ToggleOverrideField(
      (dns) => dns.fallbackLazyQuery,
      (dns, value) => dns.copyWith(fallbackLazyQuery: value),
    ),
    DnsOverrideKey.proxyServerNameserver => ListOverrideField(
      (dns) => dns.proxyServerNameserver,
      (dns, value) => dns.copyWith(proxyServerNameserver: value),
      itemMaxLength: TextInputLimits.dnsServer,
      description: (l) => l.proxyServerNameserverDesc,
    ),
    DnsOverrideKey.proxyServerNameserverPolicy => _PolicyField(
      (dns) => dns.proxyServerNameserverPolicy,
      (dns, value) => dns.copyWith(proxyServerNameserverPolicy: value),
      description: (l) => l.proxyServerNameserverPolicyDesc,
    ),
    DnsOverrideKey.directNameserver => const _DirectNameserverField(),
    DnsOverrideKey.directNameserverFollowPolicy => ToggleOverrideField(
      (dns) => dns.directNameserverFollowPolicy,
      (dns, value) => dns.copyWith(directNameserverFollowPolicy: value),
    ),
    DnsOverrideKey.fallbackFilterGeoip => ToggleOverrideField(
      (dns) => dns.fallbackFilter.geoip,
      (dns, value) => dns.copyWith.fallbackFilter(geoip: value),
    ),
    DnsOverrideKey.fallbackFilterGeoipCode => TextOverrideField(
      (dns) => dns.fallbackFilter.geoipCode,
      (dns, value) => dns.copyWith.fallbackFilter(geoipCode: value),
      maxLength: TextInputLimits.geoIpCode,
    ),
    DnsOverrideKey.fallbackFilterGeosite => ListOverrideField(
      (dns) => dns.fallbackFilter.geosite,
      (dns, value) => dns.copyWith.fallbackFilter(geosite: value),
      itemMaxLength: TextInputLimits.geoSite,
      description: (l) => l.fallbackFilterGeositeDesc,
    ),
    DnsOverrideKey.fallbackFilterIpcidr => ListOverrideField(
      (dns) => dns.fallbackFilter.ipcidr,
      (dns, value) => dns.copyWith.fallbackFilter(ipcidr: value),
      itemMaxLength: TextInputLimits.cidr,
      itemValidator: validateCidr,
      description: (l) => l.fallbackFilterIpcidrDesc,
    ),
    DnsOverrideKey.fallbackFilterDomain => ListOverrideField(
      (dns) => dns.fallbackFilter.domain,
      (dns, value) => dns.copyWith.fallbackFilter(domain: value),
      itemMaxLength: TextInputLimits.domain,
      description: (l) => l.fallbackFilterDomainDesc,
    ),
  };
}

List<String> _directDnsOf(Dns dns) => dns.directNameserver;

Dns _withDirectDns(Dns dns, List<String> servers) =>
    dns.copyWith(directNameserver: servers);

/// Karing-style direct-traffic ECS editor layered on the existing DNS override.
class _DirectNameserverField extends ValueOverrideField<Dns, List<String>> {
  const _DirectNameserverField() : super(_directDnsOf, _withDirectDns);

  @override
  Widget build(
    OverrideModel<Dns> model, {
    required ConfigLabel title,
    required Widget leading,
  }) {
    return Column(
      children: [
        ListOverrideField<Dns>(
          _directDnsOf,
          _withDirectDns,
          itemMaxLength: TextInputLimits.dnsServer,
          description: (l) => l.directNameserverDesc,
        ).build(model, title: title, leading: leading),
        _DirectDnsEcsEditor(model: model),
      ],
    );
  }
}

class _DirectDnsEcsEditor extends ConsumerWidget {
  const _DirectDnsEcsEditor({required this.model});

  final OverrideModel<Dns> model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upstreams = ref.watch(model.selectModel(_directDnsOf));
    return ConfigTextItem(
      title: (_) => '直连流量 ECS 子网',
      selector: model.selectModel(
        (dns) => sharedDirectDnsEcs(dns.directNameserver) ?? '',
      ),
      onChanged: (ref, value) {
        final current = ref.read(model.selectModel(_directDnsOf));
        final next = withDirectDnsEcs(current, value);
        model.modelWriter<List<String>>(_withDirectDns)(ref, next);
      },
      normalize: (value) => value.trim(),
      validator: (value, _) {
        if (value == null || value.isEmpty) return null;
        if (!validEcsSubnet(value)) return '请输入有效的 IPv4 或 IPv6 子网，例如 203.0.113.0/24';
        if (!hasDirectDnsEcsTargets(upstreams)) {
          return '请先设置可用的直连 DNS 服务器，system / DHCP 不支持指定 ECS';
        }
        return null;
      },
      maxLength: TextInputLimits.cidr,
      allowEmpty: true,
    );
  }
}

class _ProfileDnsOverrideSpec extends _DnsOverrideSpec
    with OverrideQuickEdit<DnsOverrideKey, Dns> {
  const _ProfileDnsOverrideSpec(super.target);

  @override
  String overrideYaml(Dns model, Set<DnsOverrideKey> keys) =>
      model.overrideYaml(keys);

  @override
  _DnsState applyOverrideYaml(Dns model, String content) {
    final result = model.applyOverrideYaml(content);
    return (model: result.dns, keys: result.keys);
  }

  @override
  EditorSchema get schema => EditorSchema.dns;
}

class _PolicyField extends ValueOverrideField<Dns, Map<String, String>> {
  const _PolicyField(super.select, super.update, {required this.description});

  final ConfigLabel description;

  @override
  Widget build(
    OverrideModel<Dns> model, {
    required ConfigLabel title,
    required Widget leading,
  }) {
    return _PolicyItem(
      model: model,
      title: title,
      description: description,
      leading: leading,
      select: select,
      update: update,
    );
  }
}

class _PolicyItem extends ConsumerWidget {
  const _PolicyItem({
    required this.model,
    required this.title,
    required this.description,
    required this.leading,
    required this.select,
    required this.update,
  });

  final OverrideModel<Dns> model;
  final ConfigLabel title;
  final ConfigLabel description;
  final Widget leading;
  final Map<String, String> Function(Dns dns) select;
  final Dns Function(Dns dns, Map<String, String> value) update;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final title = this.title(appLocalizations);
    final policy = ref.watch(model.selectModel(select));
    return ListItem.open(
      leading: leading,
      title: Text(title),
      subtitle: Text(
        policy.isEmpty
            ? appLocalizations.none
            : appLocalizations.itemsCount(policy.length),
      ),
      widget: MapEditView(
        title: title,
        description: description(appLocalizations),
        entries: policy,
        keyMaxLength: TextInputLimits.domain,
        valueMaxLength: TextInputLimits.dnsServer,
        titleBuilder: (item) => Text(item.key),
        subtitleBuilder: (item) => Text(item.value),
      ),
      onChanged: (value) {
        if (value is! Map) {
          return;
        }
        final next = Map<String, String>.from(value);
        if (!mapEquals(next, policy)) {
          model.modelWriter(update)(ref, next);
        }
      },
    );
  }
}
