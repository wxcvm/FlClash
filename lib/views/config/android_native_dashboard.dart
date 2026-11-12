import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

/// On-demand native snapshots: no background polling or Mihomo counters.
class AndroidNativeDashboard extends StatefulWidget {
  const AndroidNativeDashboard({super.key});

  @override
  State<AndroidNativeDashboard> createState() => _AndroidNativeDashboardState();
}

class _AndroidNativeDashboardState extends State<AndroidNativeDashboard> {
  final Service _service = Service();
  Map<String, dynamic>? _snapshot;
  String _message = '';
  bool _busy = false;
  bool _showLogs = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _perform(Future<String> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final message = await work();
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readSnapshot() async {
    final snapshot = await _service.getNativeSnapshot();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  Future<void> _refresh() => _perform(() async {
    await _readSnapshot();
    return '已更新原生内核数据';
  });

  Future<void> _select(String group, String tag) => _perform(() async {
    await _service.selectNativeOutbound(group, tag);
    await _readSnapshot();
    return '已提交节点切换，当前选择以策略组返回值为准';
  });

  Future<void> _test(String tag) => _perform(() async {
    await _service.testNativeOutbound(tag);
    await _readSnapshot();
    return '已请求延迟测试；结果可能尚未返回，可刷新查看';
  });

  List<Map<String, dynamic>> _rows(Object? value) =>
      (value as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  String _bytes(Object? value) {
    if (value is! num || value < 0) return '—';
    if (value < 1024) return '${value.toStringAsFixed(0)} B';
    if (value < 1048576) return '${(value / 1024).toStringAsFixed(1)} KiB';
    if (value < 1073741824) {
      return '${(value / 1048576).toStringAsFixed(1)} MiB';
    }
    return '${(value / 1073741824).toStringAsFixed(2)} GiB';
  }

  String _delay(Map<String, dynamic> row) {
    final delay = row['delay'];
    return delay is num && delay > 0 ? '${delay.toInt()} ms' : '暂无有效延迟';
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final status = Map<String, dynamic>.from(
      (snapshot?['status'] as Map?) ?? const {},
    );
    final groups = _rows(snapshot?['groups']);
    final outbounds = _rows(snapshot?['outbounds']);
    final logs = (snapshot?['logs'] as List? ?? const []).whereType<String>();
    final traffic = status['trafficAvailable'] == true;
    final rates = traffic && snapshot?['rateAvailable'] == true;
    return BaseScaffold(
      title: 'sing-box 运行管理',
      body: ValueListenableBuilder<AndroidNativeStatus?>(
        valueListenable: _service.nativeStatus,
        builder: (context, native, _) {
          final running = native?.engine == 'sing-box';
          final enabled = running && !_busy;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
              top: context.sectionsTopPadding,
              bottom: 16 + context.bottomInset,
            ),
            children: [
              generateSection(
                title: '运行概览',
                items: [
                  ListItem(
                    title: Text(running ? 'sing-box 正在运行' : '内核已停止'),
                    subtitle: Text(_busy ? '读取或执行命令中…' : '按需刷新 · 无后台轮询'),
                  ),
                  ListItem(
                    title: const Text('刷新节点、流量和日志'),
                    onTap: enabled ? () => unawaited(_refresh()) : null,
                  ),
                  if (running && snapshot != null) ...[
                    ListItem(
                      title: const Text('实时流量'),
                      subtitle: Text(rates
                          ? '↑ ${_bytes(status['upload'])}/s  ↓ ${_bytes(status['download'])}/s'
                          : '暂无可用速率样本'),
                    ),
                    ListItem(
                      title: const Text('累计流量'),
                      subtitle: Text(traffic
                          ? '↑ ${_bytes(status['uploadTotal'])}  ↓ ${_bytes(status['downloadTotal'])}'
                          : '当前配置未提供流量统计'),
                    ),
                    ListItem(
                      title: const Text('原生内核内存与连接'),
                      subtitle: Text(
                        '${_bytes(status['memory'])} · Go 协程 ${status['goroutines'] ?? '—'}'
                        ' · 连接 ${status['connections'] ?? '—'}',
                      ),
                    ),
                  ],
                ],
                footer: '内存为 sing-box 原生报告值，不是 Android 整机或应用 PSS。'
                    '流量仅在内核提供计数时展示。',
              ),
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(_message),
                ),
              if (running && snapshot?['truncated'] == true)
                const Text('节点过多，当前快照仅展示部分数据。'),
              if (running && snapshot?['warning'] is String)
                Text('原生数据流提示：${snapshot!['warning']}'),
              if (running && snapshot != null)
                for (final group in groups)
                  generateSection(
                    title: '${group['tag']} · ${group['type']}',
                    items: [
                      ListItem(
                        title: Text('当前：${group['selected']}'),
                        subtitle: Text(group['selectable'] == true
                            ? '点击成员切换'
                            : '自动组，不支持手动选择'),
                        onTap: enabled
                            ? () => unawaited(_test(group['tag'] as String))
                            : null,
                      ),
                      for (final item in _rows(group['items']))
                        ListItem(
                          title: Text(item['tag'] as String),
                          subtitle: Text('${item['type']} · ${_delay(item)}'),
                          onTap: enabled && group['selectable'] == true
                              ? () => unawaited(_select(
                                  group['tag'] as String,
                                  item['tag'] as String,
                                ))
                              : null,
                        ),
                    ],
                    footer: '点击当前组可请求延迟测试；刷新查看返回结果。',
                  ),
              if (running && outbounds.isNotEmpty)
                generateSection(
                  title: '出站节点 · 点击测试延迟',
                  items: [
                    for (final item in outbounds)
                      ListItem(
                        title: Text(item['tag'] as String),
                        subtitle: Text('${item['type']} · ${_delay(item)}'),
                        onTap: enabled
                            ? () => unawaited(_test(item['tag'] as String))
                            : null,
                      ),
                  ],
                ),
              if (running && snapshot != null)
                generateSection(
                  title: '运行日志',
                  items: [
                    ListItem(
                      title: Text(_showLogs ? '收起日志' : '查看最近日志'),
                      onTap: () => setState(() => _showLogs = !_showLogs),
                    ),
                    if (_showLogs)
                      ListItem(
                        title: SelectableText(logs.isEmpty ? '暂无日志' : logs.join('\n')),
                      ),
                  ],
                  footer: '仅显示最近 40 条原生日志，未写入额外日志文件。',
                ),
            ],
          );
        },
      ),
    );
  }
}
