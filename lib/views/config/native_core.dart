import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/clash_native_file.dart';
import 'package:fl_clash/core/desktop/native_config_kind.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_installer.dart';
import 'package:fl_clash/providers/native_core.dart';
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
  bool _busy = false;
  bool _advanced = false;

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
  }

  @override
  void dispose() {
    unawaited(_logSubscription?.cancel());
    unawaited(_handoffSubscription?.cancel());
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

  Future<String> _detectConfig() async {
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
    return '已识别 ${kind.label}，启动时自动准备内核';
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

  @override
  Widget build(BuildContext context) {
    final active = nativeCoreRuntime.activeKind;
    return BaseScaffold(
      title: '内核管理',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '内核与配置',
            items: [
              ListItem(
                title: const Text('使用当前订阅'),
                subtitle: const Text('读取有效配置并尝试转换，保留当前选择'),
                onTap: _busy || active != null || !nativeCoreInstaller.supported
                    ? null
                    : () => _perform(() => _importClash(current: true)),
              ),
              ListItem(
                title: const Text('导入 Clash 配置'),
                subtitle: const Text('自动转换、准备 sing-box 并预检'),
                onTap: _busy || active != null || !nativeCoreInstaller.supported
                    ? null
                    : () => _perform(_importClash),
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
                      ? '未运行独立内核（默认 Mihomo）'
                      : '${active.label} 正在运行',
                ),
              ),
              ListItem(
                title: const Text('系统代理接管'),
                subtitle: Text(
                  nativeCoreHandoff.ownsNativeSystemProxy ? '外部内核已接管' : '未接管',
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
              ListItem(
                title: const Text('检查配置'),
                onTap: _busy ? null : () => _perform(_validate),
              ),
              ListItem(
                title: const Text('启动独立内核'),
                onTap: _busy || active != null ? null : () => _perform(_start),
              ),
              ListItem(
                title: const Text('停止独立内核'),
                onTap:
                    _busy ||
                        (active == null &&
                            !nativeCoreHandoff.hasMihomoToRestore)
                    ? null
                    : () => _perform(_stop),
              ),
            ],
            footer:
                '默认使用 Mihomo；独立内核支持导入配置自动识别，启动需手动确认，不会按节点协议自动切换。启动时先停止 Mihomo 网络监听。sing-box / Xray 使用 JSON，Hysteria 2 使用 YAML。若 sing-box 配有 auto_route TUN，由 sing-box 管理路由与 DNS；否则使用本机 HTTP 入口接管系统代理。异常退出后恢复原 Mihomo 状态；TUN 路由状态未独立验证。',
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
