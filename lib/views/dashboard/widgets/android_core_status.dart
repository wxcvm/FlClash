import 'dart:async';

import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/config/android_core.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

import 'card.dart';

/// Android home status only; changing or importing a core stays in Advanced.
class AndroidCoreStatusCard extends StatefulWidget {
  const AndroidCoreStatusCard({super.key});

  @override
  State<AndroidCoreStatusCard> createState() => _AndroidCoreStatusCardState();
}

class _AndroidCoreStatusCardState extends State<AndroidCoreStatusCard> {
  final _service = Service();

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await _service.getNativeStatus();
    } catch (_) {
      // A stopped VPN still leaves the home page usable.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AndroidNativeStatus?>(
      valueListenable: _service.nativeStatus,
      builder: (context, status, _) {
        final engine = switch (status?.engine) {
          'mihomo' => 'Mihomo',
          'sing-box' => 'sing-box',
          'idle' => '未运行',
          _ => '正在读取',
        };
        final state = status?.state ?? '读取中';
        return DashboardCard(
          semanticLabel: '内核状态：$engine · $state',
          onTap: () => unawaited(
            showSheet<void>(
              context: context,
              builder: (_) => const AndroidCoreView(),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              const DashboardCardHeader(
                glyph: AppGlyphs.cpu,
                title: '内核状态',
                chevron: true,
              ),
              Row(
                children: [
                  Expanded(child: Text(engine)),
                  Text(state),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
