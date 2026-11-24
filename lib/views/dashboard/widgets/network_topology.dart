import 'dart:async';

import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
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

/// An inline, fitted graph. Polls only while the dashboard is active.
class NetworkTopologyCard extends ConsumerStatefulWidget {
  const NetworkTopologyCard({super.key});

  @override
  ConsumerState<NetworkTopologyCard> createState() =>
      _NetworkTopologyCardState();
}

class _NetworkTopologyCardState extends ConsumerState<NetworkTopologyCard>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<NetworkTopologyCard>,
        RouteMotionHoldMixin<NetworkTopologyCard>,
        ConnectionsPolling<NetworkTopologyCard> {
  List<TrackerInfo>? _frozen;
  late final StreamSubscription<bool> _handoff;
  late final StreamSubscription<NativeCoreExit> _exits;
  int _session = 0;

  bool get _nativeUnavailable =>
      nativeCoreHandoff.blocksMihomoStart || nativeCoreRuntime.isRunning;

  @override
  void initState() {
    super.initState();
    _handoff = nativeCoreHandoff.busyChanges.listen((_) => _resetSession());
    _exits = nativeCoreRuntime.exits.listen((_) => _resetSession());
  }

  void _resetSession() {
    if (!mounted) return;
    setState(() {
      _session++;
      _frozen = null;
      connections = const [];
      tcpCount = 0;
      udpCount = 0;
    });
    connectionCount.value = 0;
    restartPolling();
  }

  @override
  void dispose() {
    unawaited(_handoff.cancel());
    unawaited(_exits.cancel());
    super.dispose();
  }

  @override
  Future<void> poll(PollGuard isCurrent) async {
    if (_nativeUnavailable) return;
    final session = _session;
    await super.poll(
      () => isCurrent() && session == _session && !_nativeUnavailable,
    );
  }

  @override
  bool get pollsConnections => true;

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    final desktop = DashboardDensityScope.of(context).isDesktop;
    final scale = DashboardDensityScope.scaleOf(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final nativeUnavailable = _nativeUnavailable;
    final snapshot = nativeUnavailable
        ? const <TrackerInfo>[]
        : _frozen ?? connections;
    final label = nativeCoreRuntime.activeKind?.label;
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
              if (!nativeUnavailable) ...[
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
            ],
          ),
          if (nativeUnavailable)
            SizedBox(
              height: (desktop ? 260 : 220) * scale,
              child: Center(
                child: Text(
                  nativeCoreHandoff.busy
                      ? (chinese ? '正在切换内核' : 'Switching cores')
                      : (chinese
                            ? '${label ?? '独立内核'} 拓扑尚未接入仪表盘'
                            : '${label ?? 'Native core'} topology unavailable'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            TopologyGraphView(
              key: ValueKey(_session),
              routes: connectionRoutes(snapshot),
              viewportHeight: (desktop ? 260 : 220) * scale,
              fitToViewport: true,
            ),
        ],
      ),
    );
  }
}
