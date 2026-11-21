import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:karing/karing_scope.dart' as karing;

class KaringScope extends StatelessWidget {
  const KaringScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return karing.KaringScope(
      seedColor: colors.primary,
      brightness: colors.brightness,
      child: child,
    );
  }
}
