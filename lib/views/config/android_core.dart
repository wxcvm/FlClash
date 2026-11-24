import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/android_core_insight.dart';
import 'package:fl_clash/core/clash_native_file.dart';
import 'package:fl_clash/core/native_auto_recovery.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/views/config/android_native_dashboard.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/state.dart';

class AndroidCoreView extends ConsumerStatefulWidget {
  /// A read-only status page. Configuration is available from Advanced.
  const AndroidCoreView({super.key, this.readOnly = true});

  final bool readOnly;

  @override
  ConsumerState<AndroidCoreView> createState() => _AndroidCoreViewState();
}

class _AndroidCoreViewState extends ConsumerState<AndroidCoreView>
    with WidgetsBindingObserver {
  final Service _service = Service();
  String _configPath = '';
  String _result = '';
  bool _busy = false;
  bool _advanced = false;
  bool _refreshFailed = false;
  bool _refreshing = false;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    setState(() => _refreshing = true);
    try {
      await _service.getNativeStatus();
      if (mounted) setState(() => _refreshFailed = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _refreshFailed = true;
          if (!widget.readOnly) _result = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _perform(Future<String> Function() operation) async {
    if (_busy || _refreshing) return;
    setState(() {
      _busy = true;
      _progress = '正在处理…';
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

  Future<String> _importClash({
    bool current = false,
    bool startAfterImport = false,
  }) async {
    final String yaml;
    final Map<String, String> selected;
    final originalProfile = current ? ref.read(currentProfileProvider) : null;
    if (current) {
      final profile = originalProfile;
      if (profile == null) return '请先选择订阅';
      yaml = await ref
          .read(setupActionProvider.notifier)
          .getProfileWithId(profile.id);
      selected = Map<String, String>.from(profile.selectedMap);
      if (yaml.isEmpty) return '无法读取当前有效配置';
    } else {
      final file = await picker.pickerFile();
      final path = file?.path;
      if (!mounted || path == null) return '未选择配置';
      yaml = await File(path).readAsString();
      selected = const {};
    }
    if (!mounted) return '未选择配置';
    final directory = await Directory(
      await appPath.homeDirPath,
    ).createTemp('singbox-clash-');
    try {
      final candidate = await createClashNativeCandidateFromYaml(
        yaml,
        directory,
        selected: selected,
        inbounds: [
          {
            'type': 'tun',
            'tag': 'tun-in',
            'address': ['172.19.0.1/30'],
            'auto_route': true,
            'strict_route': true,
          },
        ],
      );
      if (mounted) setState(() => _progress = '正在验证配置…');
      await _service.validateNativeCore(candidate.path);
      if (!mounted) {
        await directory.delete(recursive: true);
        return '未选择配置';
      }
      if (startAfterImport &&
          ref.read(currentProfileProvider) != originalProfile) {
        await directory.delete(recursive: true);
        return '订阅已变化，请重新切换';
      }
      setState(() => _configPath = candidate.path);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
    if (startAfterImport) {
      return _start(
        requireCurrentProfile: true,
        originalProfile: originalProfile,
      );
    }
    return 'Clash 配置已转换并通过预检；原配置未修改';
  }

  Future<String> _createAutoProfile() async {
    final source = File(_configPath);
    if (await source.length() > 16 * 1024 * 1024) {
      throw const FormatException('原生配置超过 16 MiB');
    }
    final NativeAutoRecoveryConfig generated = buildNativeAutoRecovery(
      await source.readAsString(),
    );
    final directory = await Directory(
      await appPath.homeDirPath,
    ).createTemp('singbox-auto-');
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

  Future<String> _start({
    bool requireCurrentProfile = false,
    Object? originalProfile,
  }) async {
    if (!mounted) return '已取消切换';
    setState(() => _progress = '正在确认内核状态…');
    final latest = await _service.getNativeStatus();
    if (!mounted) return '已取消切换';
    if (!AndroidCoreActions(latest, refreshFailed: false).canPrepareNative) {
      return '内核状态已变化，请重新选择操作';
    }
    if (requireCurrentProfile &&
        ref.read(currentProfileProvider) != originalProfile) {
      return '订阅已变化，请重新切换';
    }
    setState(() => _progress = '正在切换内核…');
    final outcome = await _service.startNativeCore(_configPath);
    if (outcome.started) return 'sing-box VPN 已启动；请验证实际联网';
    return outcome.restoredMihomo
        ? '启动失败，已恢复 Mihomo：${outcome.error}'
        : '启动未成功：${outcome.error}';
  }

  Future<String> _switchToMihomo() async {
    final latest = await _service.getNativeStatus();
    if (!mounted) return '已取消切换';
    if (!AndroidCoreActions(latest, refreshFailed: false).nativeRunning) {
      return '内核状态已变化，请重新选择操作';
    }
    return await _service.startMihomoCore()
        ? '已切回 Mihomo'
        : '切换未完成，请检查当前 VPN 状态与配置';
  }

  Future<String> _stop() async {
    final latest = await _service.getNativeStatus();
    if (!mounted) return '已取消停止';
    if (!AndroidCoreActions(latest, refreshFailed: false).canStopNative) {
      return '内核状态已变化，请重新选择操作';
    }
    return await _service.stopNativeCore() ? 'VPN 已停止' : '停止未完成，请重试';
  }

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: widget.readOnly ? '内核状态' : '内核切换',
      body: ValueListenableBuilder<AndroidNativeStatus?>(
        valueListenable: _service.nativeStatus,
        builder: (context, status, _) {
          final available = status?.available == true;
          final actions = AndroidCoreActions(
            status,
            refreshFailed: _refreshFailed || _refreshing,
          );
          final native = actions.nativeRunning;
          final owned = status?.ownsRuntime == true;
          final busy =
              _busy ||
              _refreshing ||
              status?.state == 'STARTING' ||
              status?.state == 'STOPPING';
          final canConfigure = actions.canPrepareNative && !busy;
          final hasProfile = ref.watch(currentProfileProvider) != null;
          final insight = AndroidCoreInsight.fromStatus(
            status,
            hasProfile: hasProfile,
            refreshFailed: _refreshFailed,
          );
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
                    title: Text('${insight.engine} · ${insight.status}'),
                    subtitle: Text(insight.explanation),
                  ),
                  if (_refreshFailed)
                    ListItem(
                      title: const Text('重试读取状态'),
                      onTap: _busy || _refreshing
                          ? null
                          : () => unawaited(_refresh()),
                    ),
                ],
              ),
              if (!widget.readOnly && native)
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
              if (!widget.readOnly)
                generateSection(
                  title: '切换内核',
                  items: [
                    if (actions.settled && !native && !owned)
                      ListItem(
                        title: const Text('使用当前订阅切换到 sing-box'),
                        subtitle: Text(
                          !available
                              ? '当前安装包不支持'
                              : !hasProfile
                              ? '请先选择订阅'
                              : '自动转换、预检；启动失败时尝试恢复 Mihomo',
                        ),
                        onTap: canConfigure && hasProfile
                            ? () => _perform(
                                () => _importClash(
                                  current: true,
                                  startAfterImport: true,
                                ),
                              )
                            : null,
                      ),
                    if (native)
                      ListItem(
                        title: const Text('切回 Mihomo'),
                        subtitle: const Text('恢复原订阅配置'),
                        onTap: busy || _refreshFailed
                            ? null
                            : () => _perform(_switchToMihomo),
                      ),
                    if (native || owned)
                      ListItem(
                        title: const Text('停止 sing-box'),
                        onTap: !busy && actions.canStopNative
                            ? () => _perform(_stop)
                            : null,
                      ),
                    ListItem(
                      title: Text(_advanced ? '收起高级配置' : '高级配置'),
                      onTap: busy
                          ? null
                          : () => setState(() => _advanced = !_advanced),
                    ),
                    if (_advanced) ...[
                      ListItem(
                        title: const Text('使用当前订阅生成配置'),
                        onTap: canConfigure && hasProfile
                            ? () => _perform(() => _importClash(current: true))
                            : null,
                      ),
                      ListItem(
                        title: const Text('导入 Clash 配置'),
                        onTap: canConfigure ? () => _perform(_importClash) : null,
                      ),
                      ListItem(
                        title: const Text('导入 sing-box 配置'),
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
                        subtitle: const Text('最多 5 个原有代理；不改原配置'),
                        onTap: canConfigure && _configPath.isNotEmpty
                            ? () => _perform(_createAutoProfile)
                            : null,
                      ),
                      ListItem(
                        title: const Text('启动所选 sing-box 配置'),
                        onTap: canConfigure && _configPath.isNotEmpty
                            ? () => _perform(_start)
                            : null,
                      ),
                    ],
                  ],
                ),
              if (!widget.readOnly && _busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_progress),
                ),
              if (_result.isNotEmpty && !widget.readOnly)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(_result),
                ),
            ],
          );
        },
      ),
    );
  }
}
