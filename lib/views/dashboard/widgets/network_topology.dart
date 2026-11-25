import 'dart:async';

import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/core/desktop/native_clash_controller.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_handoff.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/native_core.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/connection/topology.dart';
import 'package:fl_clash/views/connection/topology_graph.dart';
import 'package:fl_clash/views/dashboard/layout.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';
import 'connections_table.dart';

/// Keep a dashboard snapshot scoped to the current desktop engine session.
class NetworkTopologyCard extends StatefulWidget {
  const NetworkTopologyCard({super.key, this.handoff});

  final NativeCoreHandoff? handoff;

  @override
  State<NetworkTopologyCard> createState() => _NetworkTopologyCardState();
}

class _NetworkTopologyCardState extends State<NetworkTopologyCard> {
  late final NativeCoreHandoff _handoff = widget.handoff ?? nativeCoreHandoff;
  late final StreamSubscription<bool> _busy;
  late final StreamSubscription<NativeCoreExit> _exits;
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _busy = _handoff.busyChanges.listen((_) => _resetSession());
    _exits = _handoff.runtime.exits.listen((_) => _resetSession());
  }

  void _resetSession() {
    if (mounted) setState(() => _session++);
  }

  @override
  void dispose() {
    unawaited(_busy.cancel());
    unawaited(_exits.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _handoff.runtime.activeKind?.label;
    if (!_handoff.blocksMihomoStart && !_handoff.runtime.isRunning) {
      return _MihomoTopologyCard(key: ValueKey(_session));
    }
    final spec = _handoff.runtime.activeSpec;
    if (!_handoff.busy &&
        _handoff.runtime.isRunning &&
        spec != null &&
        spec.kind == NativeCoreKind.singBox) {
      return _NativeTopologyCard(
        key: ValueKey(_session),
        handoff: _handoff,
        spec: spec,
      );
    }
    final desktop = DashboardDensityScope.of(context).isDesktop;
    final scale = DashboardDensityScope.scaleOf(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return DashboardCard(
      semanticLabel: topologyTitle(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.split,
            title: topologyTitle(context),
          ),
          SizedBox(
            height: (desktop ? 260 : 220) * scale,
            child: Center(
              child: Text(
                _handoff.busy
                    ? (chinese ? '正在切换内核' : 'Switching cores')
                    : (chinese
                          ? '${label ?? '独立内核'} 拓扑尚未接入仪表盘'
                          : '${label ?? 'Native core'} topology unavailable'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _NativeTopologyIssue { controllerUnavailable, snapshotUnavailable }

class _NativeTopologyCard extends StatefulWidget {
  const _NativeTopologyCard({
    super.key,
    required this.handoff,
    required this.spec,
  });

  final NativeCoreHandoff handoff;
  final NativeCoreSpec spec;

  @override
  State<_NativeTopologyCard> createState() => _NativeTopologyCardState();
}

class _NativeTopologyCardState extends State<_NativeTopologyCard>
    with WidgetsBindingObserver, ActivePollingMixin<_NativeTopologyCard> {
  late final Future<NativeClashController?> _controller;
  List<TrackerInfo> _connections = const [];
  List<TrackerInfo>? _frozen;
  _NativeTopologyIssue? _issue;

  bool get _currentSession =>
      widget.handoff.runtime.isRunning &&
      !widget.handoff.busy &&
      identical(widget.handoff.runtime.activeSpec, widget.spec);

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _controller = NativeClashController.fromSpec(widget.spec);
    unawaited(
      _controller.then(
        (controller) {
          if (!mounted || !_currentSession || controller != null) return;
          _updateSnapshot(const [], _NativeTopologyIssue.controllerUnavailable);
        },
        onError: (Object _, StackTrace __) {
          if (!mounted || !_currentSession) return;
          _updateSnapshot(const [], _NativeTopologyIssue.snapshotUnavailable);
        },
      ),
    );
  }

  void _updateSnapshot(
    List<TrackerInfo> connections,
    _NativeTopologyIssue? issue,
  ) {
    if (!mounted) return;
    setState(() {
      _connections = connections;
      _issue = issue;
    });
  }

  @override
  Future<void> poll(PollGuard isCurrent) async {
    final NativeClashController? controller;
    try {
      controller = await _controller;
    } catch (_) {
      if (isCurrent() && _currentSession) {
        _updateSnapshot(const [], _NativeTopologyIssue.snapshotUnavailable);
      }
      stopPolling();
      rethrow;
    }
    if (!isCurrent() || !_currentSession) return;
    if (controller == null) {
      _updateSnapshot(const [], _NativeTopologyIssue.controllerUnavailable);
      stopPolling();
      return;
    }
    try {
      final connections = await controller.connections();
      if (!isCurrent() || !_currentSession) return;
      connections.sort((a, b) => b.start.compareTo(a.start));
      _updateSnapshot(connections, null);
    } catch (_) {
      if (isCurrent() && _currentSession) {
        _updateSnapshot(const [], _NativeTopologyIssue.snapshotUnavailable);
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = DashboardDensityScope.of(context).isDesktop;
    final scale = DashboardDensityScope.scaleOf(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final snapshot = _frozen ?? _connections;
    final issue = _frozen == null ? _issue : null;
    final count = issue == null ? snapshot.length.toString() : '—';
    final status = switch (issue) {
      _NativeTopologyIssue.controllerUnavailable =>
        chinese
            ? '请在 sing-box 配置中启用带密钥的 127.0.0.1 Clash API'
            : 'Enable an authenticated 127.0.0.1 Clash API in sing-box config',
      _NativeTopologyIssue.snapshotUnavailable =>
        chinese
            ? '暂时无法读取 sing-box 连接数据，正在重试'
            : 'Cannot read sing-box connections; retrying',
      null => null,
    };
    return DashboardCard(
      semanticLabel: topologyTitle(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.split,
            title: topologyTitle(context),
            trailing: [
              Text(chinese ? 'sing-box · $count 条连接' : 'sing-box · $count'),
              PressSurface(
                fill: context.colorScheme.surfaceContainer,
                shape: AppShape.sm,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                onPressed: issue != null && _frozen == null
                    ? null
                    : () => setState(() {
                        _frozen = _frozen == null
                            ? List.unmodifiable(_connections)
                            : null;
                      }),
                child: Text(
                  _frozen == null
                      ? (chinese ? '暂停' : 'Freeze')
                      : (chinese ? '恢复' : 'Resume'),
                ),
              ),
            ],
          ),
          SizedBox(
            height: (desktop ? 260 : 220) * scale,
            child: status == null
                ? TopologyGraphView(
                    routes: connectionRoutes(snapshot),
                    viewportHeight: (desktop ? 260 : 220) * scale,
                    fitToViewport: true,
                  )
                : Center(child: Text(status, textAlign: TextAlign.center)),
          ),
        ],
      ),
    );
  }
}

class _MihomoTopologyCard extends ConsumerStatefulWidget {
  const _MihomoTopologyCard({super.key});

  @override
  ConsumerState<_MihomoTopologyCard> createState() =>
      _MihomoTopologyCardState();
}

class _MihomoTopologyCardState extends ConsumerState<_MihomoTopologyCard>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<_MihomoTopologyCard>,
        RouteMotionHoldMixin<_MihomoTopologyCard>,
        ConnectionsPolling<_MihomoTopologyCard> {
  List<TrackerInfo>? _frozen;

  @override
  bool get pollsConnections => true;

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    final desktop = DashboardDensityScope.of(context).isDesktop;
    final scale = DashboardDensityScope.scaleOf(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final snapshot = _frozen ?? connections;
    return DashboardCard(
      semanticLabel: topologyTitle(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.split,
            title: topologyTitle(context),
            trailing: [
              PressSurface(
                fill: context.colorScheme.surfaceContainer,
                shape: AppShape.sm,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                onPressed: () => setState(() {
                  _frozen = _frozen == null
                      ? List.unmodifiable(connections)
                      : null;
                }),
                child: Text(
                  _frozen == null
                      ? (chinese ? '暂停' : 'Freeze')
                      : (chinese ? '恢复' : 'Resume'),
                ),
              ),
              PressSurface(
                fill: context.colorScheme.surfaceContainer,
                shape: AppShape.sm,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                onPressed: () => openDashboardTopology(context),
                child: Text(chinese ? '详情' : 'Details'),
              ),
            ],
          ),
          TopologyGraphView(
            routes: connectionRoutes(snapshot),
            viewportHeight: (desktop ? 260 : 220) * scale,
            fitToViewport: true,
          ),
        ],
      ),
    );
  }
}
