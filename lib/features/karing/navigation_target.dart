import 'dart:io';

import 'package:fl_clash/common/context.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:flutter/widgets.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:prism_ui/icons/glyph.dart';

enum KaringPage {
  diversionRules(AppGlyphs.rules),
  dnsSettings(AppGlyphs.dns),
  backupSync(AppGlyphs.sync),
  netConnections(AppGlyphs.connections),
  serverSelect(AppGlyphs.proxies),
  urltestGroups(AppGlyphs.speed),
  qrcodeTool(AppGlyphs.qrCode),
  perApp(AppGlyphs.appsList);

  const KaringPage(this.glyph);

  final Glyph glyph;

  bool get isSupported =>
      this != perApp || Platform.isAndroid || Platform.isMacOS;

  String label(BuildContext context) {
    final translations = Translations.of(context);
    return switch (this) {
      diversionRules => translations.meta.diversionRules,
      dnsSettings => translations.meta.dns,
      backupSync => translations.meta.backupAndSync,
      netConnections => context.appLocalizations.connections,
      serverSelect => translations.ServerSelectScreen.title,
      urltestGroups => translations.meta.urlTestCustomGroup,
      qrcodeTool => translations.meta.textToQrcode,
      perApp => translations.PerAppAndroidScreen.title,
    };
  }
}
