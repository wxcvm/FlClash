import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/models/models.dart';
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
