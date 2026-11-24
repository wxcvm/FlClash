import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/connection_topology.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter/widgets.dart';

class TopologyGraphView extends StatefulWidget {
  const TopologyGraphView({
    super.key,
    required this.routes,
    this.viewportHeight = 360,
    this.fitToViewport = false,
  });

  final List<ConnectionRoute> routes;
  final double viewportHeight;
  final bool fitToViewport;

  @override
  State<TopologyGraphView> createState() => _TopologyGraphViewState();
}

class _TopologyGraphViewState extends State<TopologyGraphView> {
  static const _nodeWidth = 152.0;
  static const _nodeHeight = 58.0;
  static const _columnStep = 208.0;
  static const _rowStep = 76.0;
  TopologyNodeKey? _selected;
  TopologyNodeKey? _focus;
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _clearFocus() => setState(() {
    _focus = null;
    _transform.value = Matrix4.identity();
  });

  Widget _action(BuildContext context, String label, VoidCallback onPressed) =>
      PressSurface(
        fill: context.colorScheme.surfaceContainer,
        shape: AppShape.sm,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        onPressed: onPressed,
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final focus = _focus;
    final routes = focus == null
        ? widget.routes
        : topologyRoutesFor(widget.routes, focus);
    final graph = ConnectionGraph(routes);
    final colors = context.colorScheme;
    final labels = context.appLocalizations;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final unknown = chinese ? '未知' : 'Unknown';
    String role(TopologyRole role) => switch (role) {
      TopologyRole.source => labels.source,
      TopologyRole.rule => labels.rule,
      TopologyRole.group => labels.proxyGroup,
      TopologyRole.exit => labels.outboundExit,
    };
    String name(TopologyNodeKey key) => key.$3.isEmpty ? unknown : key.$3;
    final layers = <int, List<TopologyNodeKey>>{};
    for (final key in graph.nodes.keys) {
      layers.putIfAbsent(key.$1, () => []).add(key);
    }
    if (layers.isEmpty) {
      return Column(
        children: [
          Text(chinese ? '暂无匹配连接' : 'No matching connections'),
          if (focus != null)
            _action(
              context,
              chinese ? '显示全部路径' : 'Show all paths',
              _clearFocus,
            ),
        ],
      );
    }
    final rows = layers.values.map((keys) => keys.length).reduce(math.max);
    final lastLayer = layers.keys.reduce(math.max);
    final width = lastLayer * _columnStep + _nodeWidth + 32;
    final height = rows * _rowStep + 16;
    final positions = <TopologyNodeKey, Rect>{};
    for (final entry in layers.entries) {
      final keys = entry.value
        ..sort((a, b) {
          final byRole = a.$2.index.compareTo(b.$2.index);
          return byRole != 0 ? byRole : a.$3.compareTo(b.$3);
        });
      for (var i = 0; i < keys.length; i++) {
        positions[keys[i]] = Rect.fromLTWH(
          16 + entry.key * _columnStep,
          8 + i * _rowStep,
          _nodeWidth,
          _nodeHeight,
        );
      }
    }
    final selected = graph.nodes.containsKey(_selected) ? _selected : null;
    Color nodeColor(TopologyNodeKey key) => switch (key.$2) {
      TopologyRole.source => colors.primary,
      TopologyRole.rule => colors.tertiary,
      TopologyRole.group => colors.secondary,
      TopologyRole.exit => colors.primary,
    };
    final canvas = SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _TopologyLinks(
                positions: positions,
                graph: graph,
                color: colors.outline,
                accent: colors.primary,
                selected: selected,
              ),
            ),
          ),
          for (final entry in positions.entries)
            Positioned.fromRect(
              rect: entry.value,
              child: Semantics(
                button: true,
                selected: selected == entry.key,
                label: '${role(entry.key.$2)}: ${name(entry.key)}',
                child: GestureDetector(
                  onTap: () => setState(() {
                    _selected = selected == entry.key
                        ? null
                        : entry.key;
                  }),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: colors.surface,
                      shape: AppShape.all(10).copyWith(
                        side: BorderSide(
                          color: nodeColor(entry.key),
                          width: selected == entry.key ? 2 : 1,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              role(entry.key.$2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: nodeColor(entry.key),
                              ),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              name(entry.key),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Text(
          chinese
              ? '拖动、缩放查看路径，点击节点查看统计'
              : 'Pan and zoom; tap a node for statistics',
        ),
        if (focus != null)
          Text(
            chinese
                ? '聚焦：${name(focus)} · ${routes.length}/${widget.routes.length} 条路径'
                : 'Focused: ${name(focus)} · ${routes.length}/${widget.routes.length} paths',
          ),
        if (graph.shownPaths < graph.totalPaths)
          Text(
            chinese
                ? '图中显示 ${graph.shownPaths}/${graph.totalPaths} 条路径'
                : 'Showing ${graph.shownPaths}/${graph.totalPaths} paths',
          ),
        ClipPath(
          clipper: ShapeBorderClipper(shape: AppShape.md),
          child: ColoredBox(
            color: colors.surfaceContainer,
            child: SizedBox(
              height: widget.viewportHeight,
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: widget.fitToViewport,
                minScale: 0.25,
                maxScale: 2,
                boundaryMargin: const EdgeInsets.all(80),
                child: widget.fitToViewport
                    ? FittedBox(
                        fit: BoxFit.contain,
                        alignment: Alignment.topLeft,
                        child: canvas,
                      )
                    : canvas,
              ),
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _action(
              context,
              chinese ? '重置视图' : 'Reset view',
              () => _transform.value = Matrix4.identity(),
            ),
            if (selected != null && selected != focus)
              _action(
                context,
                chinese ? '仅显示相关路径' : 'Focus related paths',
                () => setState(() {
                  _focus = selected;
                  _transform.value = Matrix4.identity();
                }),
              ),
            if (focus != null)
              _action(
                context,
                chinese ? '显示全部路径' : 'Show all paths',
                _clearFocus,
              ),
          ],
        ),
        if (selected != null)
          Text(
            '${name(selected)} · '
            '${graph.nodes[selected]!.connections} · '
            '${dashboardTraffic(graph.nodes[selected]!.traffic)}',
          ),
      ],
    );
  }
}

class _TopologyLinks extends CustomPainter {
  const _TopologyLinks({
    required this.positions,
    required this.graph,
    required this.color,
    required this.accent,
    required this.selected,
  });

  final Map<TopologyNodeKey, Rect> positions;
  final ConnectionGraph graph;
  final Color color;
  final Color accent;
  final TopologyNodeKey? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in graph.edges.entries) {
      final from = positions[entry.key.$1]!.centerRight;
      final to = positions[entry.key.$2]!.centerLeft;
      final mid = (from.dx + to.dx) / 2;
      final highlighted = selected == entry.key.$1 || selected == entry.key.$2;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(mid, from.dy, mid, to.dy, to.dx, to.dy);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.min(5.0, 1.0 + entry.value.connections / 5)
          ..color = highlighted ? accent : color.withValues(alpha: 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TopologyLinks oldDelegate) =>
      oldDelegate.graph != graph ||
      oldDelegate.selected != selected ||
      oldDelegate.color != color ||
      oldDelegate.accent != accent;
}
