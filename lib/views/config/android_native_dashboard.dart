import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/core/native_quality_ranking.dart';
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
  final _ranking = NativeQualityRanking();
  Map<String, dynamic>? _quality;
  int _sessionStartedAt = 0;
  bool _qualityRunning = false;
  bool _qualityRequested = false;
  Timer? _qualityTimer;
  bool _qualityReading = false;

  @override
  void initState() {
    super.initState();
    _service.nativeStatus.addListener(_onNativeStatus);
    _onNativeStatus();
    unawaited(_refresh());
  }

  void _onNativeStatus() {
    final status = _service.nativeStatus.value;
    final started = status?.engine == 'sing-box' ? status!.startedAt : 0;
    if (started == _sessionStartedAt) return;
    _sessionStartedAt = started;
    _qualityTimer?.cancel();
    _qualityRequested = false;
    _ranking.clear();
    if (mounted) setState(() {
      _quality = null;
      _qualityRunning = false;
      _snapshot = null;
    });
  }

  @override
  void dispose() {
    _service.nativeStatus.removeListener(_onNativeStatus);
    _qualityTimer?.cancel();
    if (_qualityRequested) {
      unawaited(_service.cancelNativeQuality().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _startQuality(String tag) => _perform(() async {
    final session = _sessionStartedAt;
    _qualityRequested = true;
    try {
      await _service.startNativeQuality(tag);
    } catch (_) {
      _qualityRequested = false;
      rethrow;
    }
    if (!mounted || session != _sessionStartedAt) {
      if (session == _sessionStartedAt) await _service.cancelNativeQuality();
      return '测速已取消';
    }
    setState(() => _qualityRunning = true);
    await _readQuality();
    if (_qualityRunning) {
      _qualityTimer?.cancel();
      _qualityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_readQuality());
      });
    }
    return '已开始指定节点的真实网络质量测试';
  });

  Future<void> _readQuality() async {
    if (_qualityReading || !mounted) return;
    _qualityReading = true;
    final session = _sessionStartedAt;
    try {
      final result = await _service.getNativeQuality();
      if (!mounted || session != _sessionStartedAt) return;
      final sample = NativeQualitySample.fromMap(result);
      _ranking.record(sample);
      setState(() {
        _quality = result;
        _qualityRunning = sample.state == 'running';
      });
      if (!_qualityRunning) {
        _qualityRequested = false;
        _qualityTimer?.cancel();
      }
    } catch (error) {
      if (!mounted || session != _sessionStartedAt) return;
      _qualityTimer?.cancel();
      setState(() => _message = '测速状态读取失败：$error；可取消或手动刷新');
    } finally {
      _qualityReading = false;
    }
  }

  Future<void> _cancelQuality() => _perform(() async {
    await _service.cancelNativeQuality();
    await _readQuality();
    return '测速已取消';
  });

  String _bitrate(Object? value) =>
      value is num && value > 0
          ? '${(value / 1000000).toStringAsFixed(2)} Mbps'
          : '—';

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
    final quality = _quality;
    final qualityState = quality?['state'];
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
              if (running)
                generateSection(
                  title: '真实下载 / 上传测速',
                  items: [
                    ListItem(
                      title: Text(quality?['tag'] as String? ?? '尚未测速'),
                      subtitle: Text(switch (qualityState) {
                        'running' => '测速中',
                        'done' => '已完成',
                        'failed' => '测试失败：${quality?['error']}',
                        'canceled' => '已取消',
                        _ => '选择下方出站节点开始测试',
                      }),
                    ),
                    if (quality != null)
                      ListItem(
                        title: Text('↓ ${_bitrate(quality['downloadBps'])}  ↑ ${_bitrate(quality['uploadBps'])}'),
                        subtitle: Text('空闲延迟 ${quality['latencyMs'] ?? '—'} ms · 下载 RPM ${quality['downloadRpm'] ?? '—'}'),
                      ),
                    if (_qualityRunning)
                      ListItem(
                        title: const Text('取消测速'),
                        onTap: enabled ? () => unawaited(_cancelQuality()) : null,
                      ),
                    ListItem(
                      title: const Text('刷新测速状态'),
                      onTap: enabled ? () => unawaited(_readQuality()) : null,
                    ),
                  ],
                  footer: '实际消耗网络流量，单次测试最长目标 30 秒；不切换当前节点。'
                      '移动数据或限额网络请谨慎使用。',
                ),
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
                      if (group['selectable'] == true)
                        for (final best in [_ranking.recommend(
                          _rows(group['items']).map((item) => item['tag'] as String),
                          now: DateTime.now().millisecondsSinceEpoch,
                        )].whereType<String>())
                        ListItem(
                          title: Text('实测推荐：$best'),
                          subtitle: const Text('基于本次会话近期带宽、延迟和失败记录 · 点击应用'),
                          onTap: enabled && !_qualityRunning
                              ? () => unawaited(_select(group['tag'] as String, best))
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
              if (running && outbounds.isNotEmpty)
                generateSection(
                  title: '出站节点 · 真实测速',
                  items: [
                    for (final item in outbounds)
                      if (!const {'direct', 'block', 'dns', 'selector', 'urltest'}.contains(item['type']))
                        ListItem(
                          title: Text(item['tag'] as String),
                          subtitle: Text('${item['type']} · 点击进行带宽测试'),
                          onTap: enabled && !_qualityRunning
                              ? () => unawaited(_startQuality(item['tag'] as String))
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
