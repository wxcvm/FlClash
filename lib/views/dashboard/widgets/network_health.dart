import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

String _label(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

class NetworkHealthEntry extends StatelessWidget {
  const NetworkHealthEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final title = _label(context, '网络健康', 'Network health');
    void open() {
      showSheet<void>(
        context: context,
        props: nestedPagedSheetProps,
        builder: (_) =>
            NestedPagedSheet(builder: (_) => const NetworkHealthSheet()),
      );
    }

    return Semantics(
      button: true,
      label: title,
      child: Tooltip(
        message: title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: open,
          child: const SizedBox.square(
            dimension: 24,
            child: Center(child: GlyphIcon(AppGlyphs.verified, size: 18)),
          ),
        ),
      ),
    );
  }
}

class NetworkHealthSheet extends ConsumerStatefulWidget {
  const NetworkHealthSheet({super.key});

  @override
  ConsumerState<NetworkHealthSheet> createState() => _NetworkHealthSheetState();
}

class _NetworkHealthSheetState extends ConsumerState<NetworkHealthSheet> {
  Timer? _timer;
  Map<String, dynamic>? _snapshot;
  bool _reading = false;
  bool _requesting = false;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Read the cached result only while the sheet is visible. Polling does
    // not send a network probe or restart the core.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_reading || !mounted) return;
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      setState(() {
        _snapshot = null;
        _unavailable = false;
      });
      return;
    }
    _reading = true;
    try {
      final value = await ref.read(coreHandlerProvider).getNetworkHealth();
      if (!mounted) return;
      setState(() {
        _snapshot = value;
        _unavailable = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _unavailable = true;
      });
    } finally {
      _reading = false;
    }
  }

  Future<void> _check() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await ref.read(coreHandlerProvider).checkNetworkHealth();
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() => _unavailable = true);
      }
    } finally {
      if (mounted) {
        setState(() => _requesting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(coreStatusProvider) == CoreStatus.connected;
    final running = ref.watch(isStartProvider);
    final route = ref.watch(routeTrackerProvider);
    final value = _snapshot;
    final current =
        value != null &&
        (!route.synced ||
            (value['core-epoch'] == route.coreEpoch &&
                value['route-version'] == route.routeVersion));
    final snapshot = connected && running && current ? value : null;
    final state = !connected || !running
        ? 'stopped'
        : _unavailable
        ? 'unavailable'
        : snapshot?['state'] as String? ?? 'idle';
    final checking = _requesting || state == 'checking';
    final status = switch (state) {
      'stopped' => _label(context, '核心未运行', 'Core not running'),
      'checking' => _label(context, '正在验证', 'Checking'),
      'reachable' => _label(context, '测试地址可达', 'Test endpoint reachable'),
      'http-response' => _label(
        context,
        '服务返回异常状态',
        'HTTP response received',
      ),
      'dns-failure' => _label(context, 'DNS 解析失败', 'DNS lookup failed'),
      'route-unreachable' => _label(
        context,
        '出口请求失败',
        'Route request failed',
      ),
      'invalid-test-url' => _label(context, '测试地址无效', 'Invalid test URL'),
      'inconclusive' => _label(context, '未能确认', 'Inconclusive'),
      'unavailable' => _label(
        context,
        '诊断暂不可用',
        'Diagnostics unavailable',
      ),
      _ => _label(context, '尚未检测', 'Not checked'),
    };
    final dns = switch (snapshot?['dns']) {
      'failed' => _label(context, '解析失败', 'Lookup failed'),
      'resolved' => _label(context, '解析成功', 'Resolved'),
      _ => _label(context, '未单独检测', 'Not tested separately'),
    };
    final host = snapshot?['host'] as String? ?? '';
    final http = snapshot?['http-status'] as int? ?? 0;
    final delay = snapshot?['delay'] as int? ?? 0;
    final attempt = snapshot?['attempt'] as int? ?? 0;
    final source = snapshot?['source'];
    final checkedAt = snapshot?['checked-at'] as int? ?? 0;
    final time = checkedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(checkedAt).toLocal()
        : null;
    final rebuild = source == 'handover'
        ? snapshot?['rebuilt'] == true
              ? _label(context, '已重建', 'Rebuilt')
              : _label(context, '未重建', 'Not rebuilt')
        : _label(context, '不适用', 'Not applicable');
    return Scaffold(
      title: _label(context, '网络健康', 'Network health'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: _label(context, '立即诊断', 'Check now'),
          isLoading: checking,
          onPressed: connected && running && !checking ? _check : null,
        ),
      ],
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          16 + context.bottomInset,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            Text(
              status,
              style: AppTextStyle.callout.of(context, emphasized: true),
            ),
            _HealthRow(
              _label(context, '测试地址', 'Test endpoint'),
              host.isEmpty ? '—' : host,
            ),
            _HealthRow(_label(context, 'DNS 解析', 'DNS lookup'), dns),
            _HealthRow(
              _label(context, 'HTTP 状态', 'HTTP status'),
              http > 0 ? '$http' : '—',
            ),
            _HealthRow(
              _label(context, '请求延迟', 'Request latency'),
              http > 0 ? '$delay ms' : '—',
            ),
            _HealthRow(_label(context, '出口重建', 'Outbound rebuild'), rebuild),
            _HealthRow(
              _label(context, '验证次数', 'Attempts'),
              attempt > 0 ? '$attempt / 2' : '—',
            ),
            _HealthRow(
              _label(context, '最近检测', 'Last check'),
              time == null ? '—' : time.toString().split('.').first,
            ),
            Text(
              _label(
                context,
                '仅验证配置的测试地址与当前规则路由。单个网站不可达不代表所有网络断开；DNS 未单独检测时不会显示正常。诊断不会修改配置或切换节点。',
                'Checks the configured endpoint through the current route. One failed site does not prove an outage. DNS is only marked resolved after a separate lookup. Diagnostics do not change configuration or select a node.',
              ),
              style: AppTextStyle.footnote.of(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow(this.title, this.value);

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 12,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(title, style: AppTextStyle.callout.of(context))),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTextStyle.callout.of(context, emphasized: true),
          ),
        ),
      ],
    );
  }
}
