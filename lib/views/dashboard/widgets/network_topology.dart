import 'dart:async';

import 'package:fl_clash/core/connection_topology.dart';
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
