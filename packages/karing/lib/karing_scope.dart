import 'package:flutter/material.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:karing/screens/theme_define.dart';
import 'package:karing/screens/themes.dart';
import 'package:provider/provider.dart';

class KaringScope extends StatelessWidget {
  const KaringScope({
    super.key,
    required this.seedColor,
    required this.brightness,
    required this.child,
  });

  final Color seedColor;
  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = brightness == Brightness.dark
        ? ThemeDefine.kThemeDark
        : ThemeDefine.kThemeLight;
    return TranslationProvider(
      child: ChangeNotifierProvider<Themes>(
        create: (_) => Themes()..setTheme(theme, false),
        child: Theme(
          data: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: brightness,
            ),
          ),
          child: ScaffoldMessenger(child: child),
        ),
      ),
    );
  }
}
