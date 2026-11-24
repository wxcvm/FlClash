import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/clash_native_file.dart';
import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/core/desktop/native_clash_controller.dart';
import 'package:fl_clash/core/desktop/native_config_kind.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_installer.dart';
import 'package:fl_clash/core/desktop/network_diagnostics.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/native_core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/connection/topology_graph.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/state.dart';

/// Desktop-only control for native external cores.
/// System proxy and process ownership are coordinated by NativeCoreHandoff.
class NativeCoreView extends ConsumerStatefulWidget {
  const NativeCoreView({super.key});

  @override
  ConsumerState<NativeCoreView> createState() => _NativeCoreViewState();
}

class _NativeCoreViewState extends ConsumerState<NativeCoreView> {
  NativeCoreKind _kind = nativeCoreRuntime.activeKind ?? NativeCoreKind.singBox;
  String _executable =
      nativeCoreRuntime.activeSpec?.executable ??
      NativeCoreKind.singBox.executableName;
  String _configPath = nativeCoreRuntime.activeSpec?.configPath ?? '';
  final Map<NativeCoreKind, String> _configPaths = {};
  final Map<NativeCoreKind, String> _executablePaths = {};
  String _result = '';
  final List<String> _logs = [];
  StreamSubscription<String>? _logSubscription;
  StreamSubscription<String>? _handoffSubscription;
  StreamSubscription<bool>? _handoffStateSubscription;
  bool _busy = false;
  bool _advanced = false;
  int _nativeSnapshotRevision = 0;
  List<TrackerInfo>? _nativeConnections;
  Map<String, NativeProxyGroup> _nativeGroups = const {};
  String _nativeTestUrl = 'https://www.cloudflare.com/cdn-cgi/trace';

  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalledExecutable(_kind));
    void addLog(String line) {
      if (!mounted) return;
      setState(() {
        _logs.add(line.trimRight());
        if (_logs.length > 100) _logs.removeAt(0);
      });
    }

    _logSubscription = nativeCoreRuntime.logs.listen(addLog);
    _handoffSubscription = nativeCoreHandoff.messages.listen(addLog);
    _handoffStateSubscription = nativeCoreHandoff.busyChanges.listen((_) {
      _nativeSnapshotRevision++;
      if (mounted) {
        setState(() {
          _nativeConnections = null;
          _nativeGroups = const {};
      _nativeTestUrl = 'https://www.cloudflare.com/cdn-cgi/trace';
          _nativeTestUrl = 'https://www.cloudflare.com/cdn-cgi/trace';
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_logSubscription?.cancel());
    unawaited(_handoffSubscription?.cancel());
    unawaited(_handoffStateSubscription?.cancel());
    super.dispose();
  }

  Future<void> _loadInstalledExecutable(NativeCoreKind kind) async {
    final executable = await nativeCoreInstaller.installedExecutable(kind);
    if (!mounted || _kind != kind || executable == null) return;
    if (_executable == kind.executableName) {
      setState(() => _executable = executable);
    }
  }

  Future<String> _installOfficialCore() async {
    if (nativeCoreRuntime.isRunning || nativeCoreHandoff.busy) {
      throw StateError('请先停止独立内核再更新程序');
    }
    final kind = _kind;
    final installed = await nativeCoreInstaller.installLatest(kind);
    if (mounted && _kind == kind) {
      setState(() => _executable = installed.executable);
    }
    return installed.alreadyInstalled
        ? '${kind.label} ${installed.tag} 已安装，已选择程序路径'
        : '${kind.label} ${installed.tag} 安装完成，SHA-256 校验通过';
  }

  Future<void> _chooseExecutable() async {
    final file = await picker.pickerFile();
    if (!mounted || file?.path == null) return;
    setState(() => _executable = file!.path!);
  }

  Future<void> _chooseConfig() async {
    final file = await picker.pickerFile();
    if (!mounted || file?.path == null) return;
    setState(() => _configPath = file!.path!);
  }

  Future<String> _detectConfig({bool start = false}) async {
    final file = await picker.pickerFile();
    final path = file?.path;
    if (!mounted || path == null) return '未选择配置';
    final kind = detectNativeCoreKind(await File(path).readAsString());
    if (!mounted) return '';
    if (kind == null) {
      return '无法唯一识别独立内核，请手动选择；Clash 订阅仍由 Mihomo 处理';
    }
    _configPaths[_kind] = _configPath;
    _executablePaths[_kind] = _executable;
    setState(() {
      _kind = kind;
      _configPath = path;
      _executable = _executablePaths[kind] ?? kind.executableName;
    });
    await _loadInstalledExecutable(kind);
    if (!start) return '已识别 ${kind.label}，启动时自动准备内核';
    if (!mounted) return '页面已关闭，未启动内核';
    final status = await _start();
    return '已自动选择 ${kind.label}；$status';
  }

  Future<String> _importClash({bool current = false}) async {
    final String yaml;
    final Map<String, String> selected;
    if (current) {
      final profile = ref.read(currentProfileProvider);
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
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': 17890,
          },
        ],
      );
      const kind = NativeCoreKind.singBox;
      final executable =
          await nativeCoreInstaller.installedExecutable(kind) ??
          (await nativeCoreInstaller.installLatest(kind)).executable;
      final result = await nativeCoreRuntime.validate(
        NativeCoreSpec(
          kind: kind,
          executable: executable,
          configPath: candidate.path,
        ),
      );
      if (!result.valid) {
        throw StateError('转换后的配置未通过内核预检');
      }
      if (!mounted) {
        await directory.delete(recursive: true);
        return '未选择配置';
      }
      _configPaths[_kind] = _configPath;
      _executablePaths[_kind] = _executable;
      setState(() {
        _kind = kind;
        _executable = executable;
        _configPath = candidate.path;
      });
      return 'Clash 配置已转换并通过预检；原配置未修改';
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _editExecutable() async {
    final value = await dialogs.showCommonDialog<String>(
      child: InputDialog(
        title: '内核程序路径',
        value: _executable,
        hintText: '绝对路径，或 PATH 中的命令名',
      ),
    );
    if (value == null || !mounted) return;
    setState(() => _executable = value.trim());
  }

  NativeCoreSpec get _spec => NativeCoreSpec(
    kind: _kind,
    executable: _executable.trim().isEmpty
        ? _kind.executableName
        : _executable.trim(),
    configPath: _configPath.trim(),
  );

  Future<void> _perform(Future<String> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final text = await task();
      if (mounted) setState(() => _result = text);
    } catch (error) {
      if (mounted) setState(() => _result = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _validate() async {
    if (_configPath.trim().isEmpty) return '请先选择配置文件';
    final result = await nativeCoreRuntime.validate(_spec);
    if (result.valid) {
      return result.details.isEmpty ? '配置验证通过' : result.details;
    }
    return result.details.isEmpty ? '配置验证失败' : result.details;
  }

  Future<String> _start() async {
    if (_configPath.trim().isEmpty) return '请先选择配置文件';
    if (_executable == _kind.executableName && nativeCoreInstaller.supported) {
      final installed = await nativeCoreInstaller.installedExecutable(_kind);
      _executable =
          installed ??
          (await nativeCoreInstaller.installLatest(_kind)).executable;
      if (mounted) setState(() {});
    }
    await nativeCoreHandoff.activate(_spec);
    return nativeCoreHandoff.nativeTunConfigured
        ? '${_kind.label} 已启动；原生 JSON 已配置自动路由 TUN，实际路由状态未独立验证'
        : nativeCoreHandoff.ownsNativeSystemProxy
        ? '${_kind.label} 已启动，并已接管系统代理'
        : '${_kind.label} 已启动，当前仅使用原生 JSON 网络配置';
  }

  Future<String> _stop() async {
    await nativeCoreHandoff.deactivate();
    return '独立内核已停止；已按先前状态恢复 Mihomo';
  }

  Future<String> _readNativeSnapshot() async {
    final spec = nativeCoreRuntime.activeSpec;
    if (spec == null || nativeCoreHandoff.busy) return '当前没有可读取的独立内核';
    final revision = ++_nativeSnapshotRevision;
    setState(() {
      _nativeConnections = null;
      _nativeGroups = const {};
    });
    bool current() =>
        mounted &&
        revision == _nativeSnapshotRevision &&
        identical(nativeCoreRuntime.activeSpec, spec) &&
        !nativeCoreHandoff.busy;
    final controller = await NativeClashController.fromSpec(spec);
    if (!current()) return '内核会话已变化，请重新读取';
    if (controller == null) {
      return '需要已启用且配置密钥的 127.0.0.1 Clash API；本次未修改原生配置';
    }
    final results = await Future.wait([
      controller.connections(),
      controller.groups(),
    ]);
    if (!current()) return '内核会话已变化，请重新读取';
    final connections = results[0] as List<TrackerInfo>;
    final groups = results[1] as List<NativeProxyGroup>;
    setState(() {
      _nativeConnections = connections;
      _nativeGroups = {for (final group in groups) group.tag: group};
      _nativeTestUrl = controller.testUrl;
    });
    return '已读取 sing-box 当前连接与策略组快照';
  }

  Future<String> _selectNativeOutbound(String group, String outbound) async {
    final spec = nativeCoreRuntime.activeSpec;
    if (spec == null || spec.kind != NativeCoreKind.singBox) {
      return 'sing-box 会话已结束';
    }
    final revision = _nativeSnapshotRevision;
    final controller = await NativeClashController.fromSpec(spec);
    if (!mounted ||
        revision != _nativeSnapshotRevision ||
        !identical(nativeCoreRuntime.activeSpec, spec) ||
        controller == null) {
      return '内核会话已变化，未执行切换';
    }
    await controller.select(group, outbound);
    final message = await _readNativeSnapshot();
    if (_nativeGroups[group]?.selected == outbound) {
      return '已切换至 $outbound，内核返回值已确认';
    }
    return '$message；切换请求尚未由内核快照确认';
  }

  Future<String> _testNativeGroup(String groupTag) async {
    final group = _nativeGroups[groupTag];
    final spec = nativeCoreRuntime.activeSpec;
    if (group == null ||
        !group.selectable ||
        group.selected.isEmpty ||
        !group.members.contains(group.selected) ||
        spec == null ||
        spec.kind != NativeCoreKind.singBox) {
      return '当前策略组没有可测速的已选节点';
    }
    final revision = _nativeSnapshotRevision;
    final controller = await NativeClashController.fromSpec(spec);
    if (!mounted ||
        revision != _nativeSnapshotRevision ||
        !identical(nativeCoreRuntime.activeSpec, spec) ||
        controller == null) {
      return '内核会话已变化，未开始测速';
    }
    final delay = await controller.testDelay(group.selected);
    if (!mounted ||
        revision != _nativeSnapshotRevision ||
        !identical(nativeCoreRuntime.activeSpec, spec)) {
      return '内核会话已变化，测速结果未应用';
    }
    await _readNativeSnapshot();
    return '已测试 ${group.selected}：$delay ms（${controller.testUrl}）';
  }

  Future<String> _diagnose() async {
    final kind = nativeCoreRuntime.activeKind;
    final mihomoRunning = ref.read(isStartProvider);
    final config = ref.read(patchClashConfigProvider);
    final selectedGroupName = kind == null
        ? ref.read(currentProfileProvider)?.currentGroupName
        : null;
    final selectedNodeName =
        selectedGroupName == null || selectedGroupName.isEmpty
        ? null
        : ref.read(realSelectedProxyStateProvider(selectedGroupName)).proxyName;
    final followingWindowsDns =
        kind == null && await preferences.getFollowWindowsSystemDns();
    final checks =
        await DesktopNetworkDiagnostics(
          coreHealth: () => ref.read(coreHandlerProvider).getNetworkHealth(),
          nodeDns: (name) => ref.read(coreHandlerProvider).checkNodeDns(name),
          nodeHttps: (name) =>
              ref.read(coreHandlerProvider).checkNodeHttps(name),
        ).run(
          engine: kind?.label ?? 'Mihomo',
          running: kind != null || mihomoRunning,
          switching: nativeCoreHandoff.busy,
          systemProxyEnabled: ref.read(networkSettingProvider).systemProxy,
          nativeSystemProxy: nativeCoreHandoff.ownsNativeSystemProxy,
          nativeEngine: kind != null,
          proxyPort: kind != null
              ? systemProxyQueue?.nativeHttpPort
              : mihomoRunning
              ? config.mixedPort
              : null,
          tunConfigured: kind != null
              ? nativeCoreHandoff.nativeTunConfigured
              : config.tun.enable,
          followingWindowsDns: followingWindowsDns,
          selectedNodeName: selectedNodeName,
        );
    if (nativeCoreHandoff.busy ||
        nativeCoreRuntime.activeKind != kind ||
        (kind == null && ref.read(isStartProvider) != mihomoRunning) ||
        (kind == null &&
            ref.read(currentProfileProvider)?.currentGroupName !=
                selectedGroupName) ||
        (kind == null &&
            selectedGroupName != null &&
            selectedGroupName.isNotEmpty &&
            ref
                    .read(realSelectedProxyStateProvider(selectedGroupName))
                    .proxyName !=
                selectedNodeName)) {
      return '诊断过程中内核状态已变化，请重新运行';
    }
    return [
      'Windows 只读网络诊断（不修改代理、DNS 或 TUN）',
      ...checks.map((check) => check.summary),
      '说明：代理 HTTPS 仅验证 Cloudflare 测试地址；'
          '系统 DNS 和 Windows 路由读取结果不等于代理内核 DNS 或 TUN 实际接管。',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final active = nativeCoreRuntime.activeKind;
    final requiresTun =
        ref.watch(isStartProvider) &&
        ref.watch(patchClashConfigProvider).tun.enable;
    return BaseScaffold(
      title: '内核切换',
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
                title: Text(
                  nativeCoreHandoff.busy ? '正在切换' : active?.label ?? 'Mihomo',
                ),
                subtitle: Text(
                  active != null
                      ? '独立内核已运行，实际连通性仍需验证'
                      : ref.watch(isStartProvider)
                      ? '已启动'
                      : '未启动',
                ),
              ),
              if (active != null ||
                  nativeCoreHandoff.hasMihomoToRestore ||
                  nativeCoreHandoff.ownsNativeSystemProxy)
                ListItem(
                  title: const Text('恢复 Mihomo'),
                  onTap: _busy || nativeCoreHandoff.busy
                      ? null
                      : () => _perform(_stop),
                ),
            ],
          ),
          generateSection(
            title: '切换内核',
            items: [
              ListItem(
                title: const Text('使用当前订阅准备 sing-box'),
                subtitle: Text(
                  requiresTun
                      ? '当前使用 TUN；转换仅准备本地代理，切换需要原生 TUN 配置'
                      : '自动转换并预检，不立即切换当前连接',
                ),
                onTap: _busy || active != null || !nativeCoreInstaller.supported
                    ? null
                    : () => _perform(() => _importClash(current: true)),
              ),
              ListItem(
                title: Text('切换到 ${_kind.label}'),
                onTap:
                    _busy ||
                        _configPath.trim().isEmpty ||
                        nativeCoreHandoff.busy ||
                        active != null ||
                        nativeCoreHandoff.ownsNativeSystemProxy ||
                        nativeCoreHandoff.hasMihomoToRestore
                    ? null
                    : () => _perform(_start),
              ),
              ListItem(
                title: const Text('导入 Clash 配置'),
                subtitle: const Text('自动转换、准备 sing-box 并预检'),
                onTap: _busy || active != null || !nativeCoreInstaller.supported
                    ? null
                    : () => _perform(_importClash),
              ),
              ListItem(
                title: const Text('自动识别并启动内核'),
                subtitle: const Text('按原生配置选择内核、安装预检并安全接管；无法识别则不切换'),
                onTap:
                    _busy ||
                        active != null ||
                        nativeCoreHandoff.busy ||
                        nativeCoreHandoff.ownsNativeSystemProxy ||
                        nativeCoreHandoff.hasMihomoToRestore
                    ? null
                    : () => _perform(() => _detectConfig(start: true)),
              ),
              ListItem(
                title: const Text('自动识别内核配置'),
                subtitle: const Text('导入原生配置，启动时自动准备对应内核'),
                onTap: _busy || active != null
                    ? null
                    : () => _perform(_detectConfig),
              ),
              ListItem(
                title: Text(_advanced ? '收起高级设置' : '展开高级设置'),
                onTap: _busy
                    ? null
                    : () => setState(() => _advanced = !_advanced),
              ),
              if (_advanced) ...[
                ListItem<NativeCoreKind>.options(
                  title: const Text('内核'),
                  options: NativeCoreKind.values,
                  value: _kind,
                  textBuilder: (kind) => kind.label,
                  onChanged: (kind) {
                    if (_busy || active != null) return;
                    _configPaths[_kind] = _configPath;
                    _executablePaths[_kind] = _executable;
                    setState(() {
                      _kind = kind;
                      _executable =
                          _executablePaths[kind] ?? kind.executableName;
                      _configPath = _configPaths[kind] ?? '';
                    });
                    unawaited(_loadInstalledExecutable(kind));
                  },
                ),
                ListItem(
                  title: const Text('下载 / 更新官方稳定版'),
                  subtitle: Text(
                    nativeCoreInstaller.supported
                        ? 'Windows / Linux / macOS，自动校验 SHA-256'
                        : '当前平台请手动选择内核程序',
                  ),
                  onTap:
                      _busy ||
                          nativeCoreRuntime.isRunning ||
                          !nativeCoreInstaller.supported
                      ? null
                      : () => _perform(_installOfficialCore),
                ),
                ListItem(
                  title: const Text('选择内核程序'),
                  subtitle: Text(_executable),
                  onTap: _busy ? null : _chooseExecutable,
                ),
                ListItem(
                  title: const Text('手动填写程序路径'),
                  onTap: _busy ? null : _editExecutable,
                ),
                ListItem(
                  title: Text(
                    _kind == NativeCoreKind.hysteria2
                        ? '选择原生 YAML 配置'
                        : '选择原生 JSON 配置',
                  ),
                  subtitle: Text(
                    _configPath.isEmpty ? '尚未选择' : _configPath,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _busy ? null : _chooseConfig,
                ),
              ],
            ],
          ),
          generateSection(
            title: '运行',
            items: [
              ListItem(
                title: const Text('运行状态'),
                subtitle: Text(
                  active == null
                      ? ref.watch(isStartProvider)
                            ? 'Mihomo 已启动（外网连通性未验证）'
                            : '内核未运行'
                      : '${active.label} 进程运行中（外网连通性未验证）',
                ),
              ),
              ListItem(
                title: const Text('系统代理接管'),
                subtitle: Text(
                  nativeCoreHandoff.ownsNativeSystemProxy
                      ? '系统代理已设置（不代表代理出口可用）'
                      : '未由独立内核设置',
                ),
              ),
              ListItem(
                title: const Text('原生 TUN'),
                subtitle: Text(
                  nativeCoreHandoff.nativeTunConfigured
                      ? 'sing-box 已配置 TUN 自动路由，未独立验证实际网络接管'
                      : '未启动原生 TUN 自动路由',
                ),
              ),
              if (system.isWindows)
                ListItem(
                  title: const Text('一键诊断 Windows 网络'),
                  subtitle: const Text(
                    '只读检查代理、系统 DNS、节点入口 DNS、节点 HTTPS、历史证据和 TUN 路由',
                  ),
                  onTap: _busy || nativeCoreHandoff.busy
                      ? null
                      : () => _perform(_diagnose),
                ),
              ListItem(
                title: const Text('检查配置'),
                onTap: _busy ? null : () => _perform(_validate),
              ),
            ],
            footer:
                '默认使用 Mihomo；独立内核配置可自动识别并一键启动，也可仅识别后手动启动；不会根据测速或当前节点自动切换。启动时先停止 Mihomo 网络监听。sing-box / Xray 使用 JSON，Hysteria 2 使用 YAML。若 sing-box 配有 auto_route TUN，由 sing-box 管理路由与 DNS；否则使用本机 HTTP 入口接管系统代理。已验证本机 HTTP 代理入口的独立内核异常退出时自动重启一次，仍失败则恢复 Mihomo；TUN 异常直接恢复 Mihomo，路由状态未独立验证。',
          ),
          if (active == NativeCoreKind.singBox)
            generateSection(
              title: 'sing-box 连接与策略组',
              items: [
                ListItem(
                  title: const Text('刷新原生连接快照'),
                  subtitle: const Text('使用已配置的本机 Clash API，不额外开启监听'),
                  onTap: _busy || nativeCoreHandoff.busy
                      ? null
                      : () => _perform(_readNativeSnapshot),
                ),
                if (_nativeConnections case final connections?) ...[
                  ListItem(title: Text('当前连接：${connections.length}')),
                  for (final group in _nativeGroups.values)
                    if (group.selectable &&
                        group.selected.isNotEmpty &&
                        group.members.contains(group.selected)) ...[
                      ListItem<String>.options(
                        title: Text(group.tag),
                        subtitle: Text(
                          'sing-box Selector · '
                          '${group.selectedDelayMs == null ? '暂无延迟' : '${group.selectedDelayMs} ms'}',
                        ),
                        options: group.members,
                        value: group.selected,
                        textBuilder: (tag) => tag,
                        onChanged: (tag) => _perform(
                          () => _selectNativeOutbound(group.tag, tag),
                        ),
                      ),
                      ListItem(
                        title: const Text('测试当前节点延迟'),
                        subtitle: Text('测试地址：$_nativeTestUrl'),
                        onTap: _busy
                            ? null
                            : () => _perform(
                                () => _testNativeGroup(group.tag),
                              ),
                      ),
                    ] else
                      ListItem(
                        title: Text(group.tag),
                        subtitle: Text('${group.type} · ${group.selected}'),
                      ),
                  TopologyGraphView(
                    key: ValueKey(_nativeSnapshotRevision),
                    routes: connectionRoutes(connections),
                    viewportHeight: 260,
                    fitToViewport: true,
                  ),
                ],
              ],
              footer: '按需读取当前 sing-box 实际数据；不显示 Mihomo 缓存或自动切换节点。',
            ),
          if (_result.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(_result),
            ),
          if (_logs.isNotEmpty)
            generateSection(
              title: '运行日志',
              items: [ListItem(title: SelectableText(_logs.join('\n')))],
            ),
        ],
      ),
    );
  }
}
