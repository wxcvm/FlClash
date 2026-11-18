import 'dart:async';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/native_core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/config/native_core.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

/// Report the active desktop engine, not just the Mihomo controller connection.
String desktopCoreStatusLabel({
  required NativeCoreKind? externalCore,
  required bool switching,
  required bool mihomoRunning,
  required CoreStatus mihomoStatus,
}) {
  if (switching) return '内核切换中';
  if (externalCore != null) return '${externalCore.label} · 运行中';
  if (!mihomoRunning) return '内核未运行';
  return switch (mihomoStatus) {
    CoreStatus.connecting => 'Mihomo · 连接中',
    CoreStatus.connected => 'Mihomo · 运行中',
    CoreStatus.disconnected => 'Mihomo · 连接异常',
  };
}

/// A passive desktop status entry. Switching remains in Advanced > Core.
class DesktopCoreStatusButton extends ConsumerStatefulWidget {
  const DesktopCoreStatusButton({super.key});

  @override
  ConsumerState<DesktopCoreStatusButton> createState() =>
      _DesktopCoreStatusButtonState();
}

class _DesktopCoreStatusButtonState
    extends ConsumerState<DesktopCoreStatusButton> {
  late final StreamSubscription<NativeCoreExit> _exits;
  late final StreamSubscription<String> _handoff;

  @override
  void initState() {
    super.initState();
    _exits = nativeCoreRuntime.exits.listen((_) => _refresh());
    _handoff = nativeCoreHandoff.messages.listen((_) => _refresh());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_exits.cancel());
    unawaited(_handoff.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = desktopCoreStatusLabel(
      externalCore: nativeCoreRuntime.activeKind,
      switching: nativeCoreHandoff.busy,
      mihomoRunning: ref.watch(isStartProvider),
      mihomoStatus: ref.watch(coreStatusProvider),
    );
    final compact =
        MediaQuery.sizeOf(context).width < 1100 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.25;
    void openManagement() => showSheet<void>(
      context: context,
      builder: (_) => const NativeCoreView(),
    );
    return Tooltip(
      message: '内核状态：$label · 打开内核管理',
      child: compact
          ? IconButton.filled(
              onPressed: openManagement,
              icon: const GlyphIcon(AppGlyphs.cpu, fill: 1),
            )
          : FilledButton.icon(
              onPressed: openManagement,
              icon: const GlyphIcon(AppGlyphs.cpu, fill: 1),
              label: Text(label),
            ),
    );
  }
}
