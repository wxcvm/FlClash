import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter/widgets.dart';

import 'topology_graph.dart';

String topologyTitle(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh'
        ? '网络拓扑'
        : 'Network topology';

/// Uses the existing live feed's filtered snapshot and scroll controller.
/// Rows are built lazily; no separate core subscription or graph dependency.
class ConnectionTopology extends StatelessWidget {
  const ConnectionTopology({
    super.key,
    required this.connections,
    required this.controller,
    required this.padding,
  });

  final List<TrackerInfo> connections;
  final ScrollController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final routes = connectionRoutes(connections);
    final graph = ConnectionGraph(routes);
    final labels = context.appLocalizations;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final unknown = chinese ? '未知' : 'Unknown';
    return ListView.builder(
      controller: controller,
      padding: padding.add(const EdgeInsets.symmetric(horizontal: 16)),
      itemCount: routes.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Text(
                  chinese
                      ? '${connections.length} 个连接 · ${routes.length} 条路径'
                      : '${connections.length} connections · ${routes.length} paths',
                ),
                TopologyGraphView(graph: graph),
                Text(chinese ? '完整连接路径' : 'Complete connection paths'),
              ],
            ),
          );
        }
        final route = routes[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    '${route.connections} · ${dashboardTraffic(route.traffic)}',
                    style: TextStyle(color: context.colorScheme.primary),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _RouteNode(
                        label: labels.source,
                        value: route.source.isEmpty ? unknown : route.source,
                      ),
                      const Text('→'),
                      _RouteNode(
                        label: labels.rule,
                        value: route.rule.isEmpty ? unknown : route.rule,
                      ),
                      for (var i = 0; i < route.hops.length; i++) ...[
                        const Text('→'),
                        _RouteNode(
                          label: i == route.hops.length - 1
                              ? labels.outboundExit
                              : labels.proxyGroup,
                          value: route.hops[i].isEmpty ? unknown : route.hops[i],
                        ),
                      ],
                      if (route.hops.isEmpty) ...[
                        const Text('→'),
                        _RouteNode(label: labels.outboundExit, value: unknown),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RouteNode extends StatelessWidget {
  const _RouteNode({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
            Text(value, softWrap: true),
          ],
        ),
      ),
    );
  }
}
