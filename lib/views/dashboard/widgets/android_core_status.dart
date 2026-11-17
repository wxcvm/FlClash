import 'dart:async';

import 'package:fl_clash/core/android_core_insight.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/config/android_core.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';

/// A passive status view; core changes remain in Advanced.
class AndroidCoreStatusCard extends ConsumerStatefulWidget {
  const AndroidCoreStatusCard({super.key});

  @override
  ConsumerState<AndroidCoreStatusCard> createState() =>
      _AndroidCoreStatusCardState();
}

class _AndroidCoreStatusCardState extends ConsumerState<AndroidCoreStatusCard>
    with WidgetsBindingObserver {
  final _service = Service();
  bool _refreshFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await _service.getNativeStatus();
      if (mounted) setState(() => _refreshFailed = false);
    } catch (_) {
      if (mounted) setState(() => _refreshFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasProfile = ref.watch(currentProfileProvider) != null;
    return ValueListenableBuilder<AndroidNativeStatus?>(
      valueListenable: _service.nativeStatus,
      builder: (context, status, _) {
        final insight = AndroidCoreInsight.fromStatus(
          status,
          hasProfile: hasProfile,
          refreshFailed: _refreshFailed,
        );
        return DashboardCard(
          semanticLabel: '内核状态：${insight.engine} · ${insight.status}',
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
                  Expanded(child: Text(insight.engine)),
                  Text(insight.status),
                ],
              ),
              Text(
                insight.suggestion,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }
}
