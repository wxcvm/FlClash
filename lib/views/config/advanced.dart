import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/config/dns.dart';
import 'package:fl_clash/views/config/filters.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/views/config/icon_sets.dart';
import 'package:fl_clash/views/config/mitm.dart';
import 'package:fl_clash/views/config/native_core.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/views/config/providers.dart';
import 'package:fl_clash/views/config/scripts.dart';
import 'package:fl_clash/views/dashboard/widgets/core_status_button.dart';
import 'package:fl_clash/views/profiles/custom/custom_proxies.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rules.dart';

class AdvancedConfigView extends StatelessWidget {
  const AdvancedConfigView({super.key});

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final items = [
      if (system.isDesktop || system.isAndroid)
        ListItem.open(
          title: const Text('内核管理'),
          leading: const GlyphIcon(AppGlyphs.cpu),
          widget: system.isDesktop
              ? const NativeCoreView()
              : const AndroidCoreView(),
        ),
      ListItem.open(
        title: Text(appLocalizations.network),
        leading: const GlyphIcon(AppGlyphs.key),
        widget: BaseScaffold(
          title: appLocalizations.network,
          body: const NetworkListView(),
        ),
      ),
      ListItem.open(
        title: const Text('DNS'),
        leading: const GlyphIcon(AppGlyphs.dns),
        widget: const DnsView(),
      ),
      ListItem.open(
        title: Text(appLocalizations.addedRules),
        leading: const GlyphIcon(AppGlyphs.rules),
        widget: const AddedRulesView(),
      ),
      ListItem.open(
        title: Text(appLocalizations.script),
        leading: const GlyphIcon(AppGlyphs.code),
        widget: const ScriptsView(),
      ),
      if (mitmFeature)
        ListItem.open(
          title: Text(appLocalizations.mitm),
          leading: const GlyphIcon(AppGlyphs.lockOpen),
          widget: MitmView(isAndroid: system.isAndroid),
        ),
    ];
    final customItems = [
      ListItem.open(
        title: Text(appLocalizations.proxies),
        leading: const GlyphIcon(AppGlyphs.proxies),
        widget: const CustomProxiesView(),
      ),
      ListItem.open(
        title: Text(appLocalizations.ruleProviders),
        leading: const GlyphIcon(AppGlyphs.resources),
        widget: const ClashProvidersView(),
      ),
      ListItem.open(
        title: Text(appLocalizations.filters),
        leading: const GlyphIcon(AppGlyphs.filter),
        widget: const FiltersView(),
      ),
      ListItem.open(
        title: Text(appLocalizations.iconSets),
        leading: const GlyphIcon(AppGlyphs.photos),
        widget: const IconSetsView(),
      ),
    ];
    return BaseScaffold(
      title: appLocalizations.advancedConfig,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(items: items),
          generateSection(
            title: appLocalizations.customResources,
            items: customItems,
          ),
        ],
      ),
    );
  }
}

class AndroidCoreView extends ConsumerWidget {
  const AndroidCoreView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.appLocalizations;
    final status = ref.watch(coreStatusProvider);
    return BaseScaffold(
      title: '内核管理',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '当前内核',
            items: [
              const ListItem(
                title: Text('Mihomo'),
                subtitle: Text('内置 · 随应用更新'),
              ),
              ListItem(
                title: Text(l.coreStatus),
                subtitle: Text(switch (status) {
                  CoreStatus.connecting => l.connecting,
                  CoreStatus.connected => l.connected,
                  CoreStatus.disconnected => l.disconnected,
                }),
                trailing: const CoreStatusButton(),
              ),
            ],
            footer: 'Android 使用内置 Mihomo。点击状态按钮可重启内核；'
                '当前不支持切换独立 sing-box、Xray 或 Hysteria 2。',
          ),
          generateSection(
            title: '内核配置',
            items: [
              ListItem.open(
                title: Text(l.general),
                widget: const GeneralView(),
              ),
              ListItem.open(
                title: Text(l.network),
                widget: BaseScaffold(
                  title: l.network,
                  body: const NetworkListView(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
