import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/providers/native_core.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Desktop-only control for native external cores.
/// This does not claim the system proxy or the Mihomo-managed VPN/TUN.
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
  String _result = '';
  final List<String> _logs = [];
  StreamSubscription<String>? _logSubscription;
  StreamSubscription<String>? _handoffSubscription;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
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
    if (_configPath.trim().isEmpty) return '请先选择 JSON 配置文件';
    final result = await nativeCoreRuntime.validate(_spec);
    if (result.valid) {
      return result.details.isEmpty ? '配置验证通过' : result.details;
    }
    return result.details.isEmpty ? '配置验证失败' : result.details;
  }

  Future<String> _start() async {
    if (_configPath.trim().isEmpty) return '请先选择 JSON 配置文件';
    await nativeCoreHandoff.activate(_spec);
    return '${_kind.label} 已启动；Mihomo 网络接管已暂时停止；独立内核尚未自动设置系统代理';
  }

  Future<String> _stop() async {
    await nativeCoreHandoff.deactivate();
    return '独立内核已停止；已按先前状态恢复 Mihomo';
  }

  @override
  Widget build(BuildContext context) {
    final active = nativeCoreRuntime.activeKind;
    return BaseScaffold(
      title: '独立内核',
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '内核与配置',
            items: [
              ListItem<NativeCoreKind>.options(
                title: const Text('内核'),
                options: NativeCoreKind.values,
                value: _kind,
                textBuilder: (kind) => kind.label,
                onChanged: (kind) {
                  setState(() {
                    final previousDefault = _kind.executableName;
                    _kind = kind;
                    if (_executable == previousDefault) {
                      _executable = kind.executableName;
                    }
                  });
                },
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
                title: const Text('选择原生 JSON 配置'),
                subtitle: Text(
                  _configPath.isEmpty ? '尚未选择' : _configPath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _busy ? null : _chooseConfig,
              ),
            ],
          ),
          generateSection(
            title: '运行',
            items: [
              ListItem(
                title: const Text('运行状态'),
                subtitle: Text(
                  active == null ? '未运行独立内核' : '${active.label} 正在运行',
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
                onTap: _busy || (active == null && !nativeCoreHandoff.hasMihomoToRestore)
                    ? null
                    : () => _perform(_stop),
              ),
            ],
            footer: '启动前会先停用 Mihomo 的网络监听；停止独立内核后恢复原状态。不会自动接管系统代理或转换 JSON 配置。',
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
