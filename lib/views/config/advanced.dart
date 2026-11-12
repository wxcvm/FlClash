import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/action.dart';
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

class AndroidCoreView extends ConsumerStatefulWidget {
  const AndroidCoreView({super.key});

  @override
  ConsumerState<AndroidCoreView> createState() => _AndroidCoreViewState();
}

class _AndroidCoreViewState extends ConsumerState<AndroidCoreView> {
  bool _available = false;
  bool _active = false;
  bool _busy = false;
  String _path = '';
  String _message = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await service?.nativeStatus() ?? const {};
      if (!mounted) return;
      setState(() {
        _available = status['available'] == true;
        _active = status['active'] == true;
        if (_active) _path = status['path'] as String? ?? _path;
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _perform(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _choose() async {
    final selected = await picker.pickerFile();
    final path = selected?.path;
    if (path == null || !mounted) return '未选择配置';
    final source = File(path);
    if (await source.length() > 16 * 1024 * 1024) return '配置超过 16 MiB';
    final folder = await appPath.profilesPath;
    final target = File('$folder/android-singbox.json');
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    if (mounted) setState(() => _path = target.path);
    return '已导入 JSON；启动时执行原生配置验证';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final status = ref.watch(coreStatusProvider);
    final running = ref.watch(isStartProvider);
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
              ListItem(
                title: Text(_active ? 'sing-box' : 'Mihomo'),
                subtitle: Text(_active ? '独立 VPN 正在运行' : '内置 · 随应用更新'),
              ),
              if (!_active)
                ListItem(
                  title: Text(l.coreStatus),
                  subtitle: Text(switch (status) {
                    CoreStatus.connecting => l.connecting,
                    CoreStatus.connected => l.connected,
                    CoreStatus.disconnected => l.disconnected,
                  }),
                  trailing: const CoreStatusButton(),
                ),
              ListItem(
                title: const Text('刷新运行状态'),
                onTap: _busy ? null : _refresh,
              ),
            ],
          ),
          generateSection(
            title: 'sing-box 原生配置',
            items: [
              ListItem(
                title: const Text('官方 sing-box 1.14.4'),
                subtitle: Text(_available ? '已安装 · 实验性 VPN' : '当前 APK 未包含原生内核'),
              ),
              ListItem(
                title: const Text('导入 sing-box JSON'),
                subtitle: Text(_path.isEmpty ? '选择包含 TUN 的完整配置' : _path),
                onTap: !_available || _busy || _active ? null : () => _perform(_choose),
              ),
              ListItem(
                title: const Text('启动 sing-box'),
                onTap: !_available || _busy || _active || _path.isEmpty
                    ? null
                    : () => _perform(() async {
                        final started = await ref.read(setupActionProvider.notifier).startAndroidNative(_path);
                        return started ? 'sing-box VPN 已启动' : '启动失败；请检查配置及 VPN 授权';
                      }),
              ),
              ListItem(
                title: const Text('停止 sing-box / 返回 Mihomo'),
                onTap: _busy || !_active ? null : () => _perform(() async {
                  await ref.read(setupActionProvider.notifier).setRunning(false);
                  return '已停止；可使用普通连接按钮启动 Mihomo';
                }),
              ),
            ],
            footer: '原生 JSON 独立管理路由及 DNS。Clash 订阅仍使用 Mihomo。'
                '原生节点列表和流量统计尚未接入，不会用 Mihomo 数据冒充。',
          ),
          if (_message.isNotEmpty)
            Padding(padding: const EdgeInsets.all(12), child: SelectableText(_message)),
          if (!_active)
            generateSection(
              title: 'Mihomo 配置',
              items: [
                ListItem.open(title: Text(l.general), widget: const GeneralView()),
                ListItem.open(
                  title: Text(l.network),
                  widget: BaseScaffold(title: l.network, body: const NetworkListView()),
                ),
                if (running)
                  const ListItem(title: Text('当前普通连接正在运行')),
              ],
            ),
        ],
      ),
    );
  }
}
