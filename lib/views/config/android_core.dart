import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/native_auto_recovery.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/views/config/android_native_dashboard.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

class AndroidCoreView extends StatefulWidget {
  const AndroidCoreView({super.key});

  @override
  State<AndroidCoreView> createState() => _AndroidCoreViewState();
}

class _AndroidCoreViewState extends State<AndroidCoreView> {
  final Service _service = Service();
  String _configPath = '';
  String _result = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await _service.getNativeStatus();
    } catch (error) {
      if (mounted) setState(() => _result = error.toString());
    }
  }

  Future<void> _perform(Future<String> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = '';
    });
    try {
      final result = await operation();
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _result = error.toString());
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _choose() async {
    final file = await picker.pickerFile();
    if (!mounted || file?.path == null) return '未选择配置';
    setState(() => _configPath = file!.path!);
    return '已选择原生配置，启动前将进行完整预检';
  }

  Future<String> _createAutoProfile() async {
    final source = File(_configPath);
    if (await source.length() > 16 * 1024 * 1024) {
      throw const FormatException('原生配置超过 16 MiB');
    }
    final generated = buildNativeAutoRecovery(await source.readAsString());
    final directory = await Directory(await appPath.homeDirPath).createTemp('singbox-auto-');
    final copy = File('${directory.path}/config.json');
    try {
      await copy.writeAsString(generated.json, flush: true);
      await _service.validateNativeCore(copy.path);
      if (!mounted) {
        await directory.delete(recursive: true);
        return '未选择自动恢复配置';
      }
      setState(() => _configPath = copy.path);
      return '已生成并验证配置副本：${generated.addedGroups.join('、')}。'
          '启动后在策略组中选择新增自动组，原配置未修改。';
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> _validate() async {
    final version = await _service.validateNativeCore(_configPath);
    return 'sing-box $version 配置验证通过；未改变当前 VPN';
  }

  Future<String> _start() async {
    final outcome = await _service.startNativeCore(_configPath);
    if (outcome.started) return 'sing-box VPN 已启动；请验证实际联网';
    return outcome.restoredMihomo
        ? '启动失败，已恢复 Mihomo：${outcome.error}'
        : '启动未成功：${outcome.error}';
  }

  Future<String> _switchToMihomo() async =>
      await _service.startMihomoCore()
          ? '已切回 Mihomo'
          : '切换未完成，请检查当前 VPN 状态与配置';

  Future<String> _stop() async =>
      await _service.stopNativeCore() ? 'VPN 已停止' : '停止未完成，请重试';

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return BaseScaffold(
      title: '内核管理',
      body: ValueListenableBuilder<AndroidNativeStatus?>(
        valueListenable: _service.nativeStatus,
        builder: (context, status, _) {
          final available = status?.available == true;
          final native = status?.engine == 'sing-box';
          final owned = status?.nativeOwner == true;
          final busy = _busy || status?.state == 'STARTING';
          final canConfigure = available && !owned && !busy;
          final engine = switch (status?.engine) {
            'sing-box' => 'sing-box',
            'mihomo' => 'Mihomo',
            'idle' => owned ? '原生内核清理待完成' : '未运行',
            _ => '正在读取',
          };
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
              top: context.sectionsTopPadding,
              bottom: 16 + context.bottomInset,
            ),
            children: [
              generateSection(
                title: '当前内核',
                items: [
                  ListItem(
                    title: Text(engine),
                    subtitle: Text(status?.state ?? '正在读取状态'),
                  ),
                  const ListItem(
                    title: Text('Mihomo'),
                    subtitle: Text('内置 · 默认内核'),
                  ),
                  ListItem(
                    title: const Text('sing-box'),
                    subtitle: Text(
                      available
                          ? '原生内核可用 · ARM64'
                          : '当前 APK 未包含可用原生内核',
                    ),
                  ),
                  ListItem(
                    title: const Text('刷新运行状态'),
                    onTap: busy ? null : () => unawaited(_refresh()),
                  ),
                ],
              ),
              if (native)
                generateSection(
                  title: 'sing-box 运行管理',
                  items: [
                    ListItem.open(
                      title: const Text('节点、流量与日志'),
                      subtitle: const Text('原生策略组、延迟、运行数据'),
                      widget: const AndroidNativeDashboard(),
                    ),
                  ],
                ),
              generateSection(
                title: 'sing-box 原生配置',
                items: [
                  ListItem(
                    title: const Text('选择 JSON 配置'),
                    subtitle: Text(
                      _configPath.isEmpty ? '尚未选择' : _configPath,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: canConfigure ? () => _perform(_choose) : null,
                  ),
                  ListItem(
                    title: const Text('检查配置'),
                    onTap: canConfigure && _configPath.isNotEmpty
                        ? () => _perform(_validate)
                        : null,
                  ),
                  ListItem(
                    title: const Text('生成自动恢复配置副本'),
                    subtitle: const Text('最多 5 个原有代理组成原生自动组；不改原文件或默认路由'),
                    onTap: canConfigure && _configPath.isNotEmpty
                        ? () => _perform(_createAutoProfile)
                        : null,
                  ),
                  ListItem(
                    title: const Text('启动 / 切换到 sing-box'),
                    onTap: canConfigure && _configPath.isNotEmpty
                        ? () => _perform(_start)
                        : null,
                  ),
                  if (native)
                    ListItem(
                      title: const Text('切回 Mihomo'),
                      subtitle: const Text('停止 sing-box 后恢复原订阅配置'),
                      onTap: busy ? null : () => _perform(_switchToMihomo),
                    ),
                  ListItem(
                    title: const Text('停止 sing-box'),
                    onTap: !busy && (native || owned)
                        ? () => _perform(_stop)
                        : null,
                  ),
                ],
                footer: '使用带 TUN 的 sing-box 原生 JSON；不会转换 Clash 订阅。'
                    '启动失败时尝试恢复先前的 Mihomo VPN。'
                    '节点、流量与日志可在运行管理查看；选择原生自动组后由内核重新选路。',
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('正在处理，请勿重复切换…'),
                ),
              if (_result.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(_result),
                ),
              generateSection(
                title: 'Mihomo 配置',
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
          );
        },
      ),
    );
  }
}
