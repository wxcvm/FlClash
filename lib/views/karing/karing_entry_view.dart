import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/karing/navigation_target.dart';
import 'package:fl_clash/features/karing/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

import 'karing_screen.dart';

class KaringEntryView extends ConsumerWidget {
  const KaringEntryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(karingServersProvider);
    return Scaffold(
      title: PageLabel.karing.label,
      body: Builder(
        builder: (context) => PrismListView(
          itemCount: 1,
          itemBuilder: (_, _) => generateSection(
            items: KaringPage.values.map(
              (page) => page.isSupported
                  ? ListItem<void>.open(
                      leading: GlyphIcon(page.glyph),
                      title: Text(page.label(context)),
                      widget: KaringScreen(page: page),
                      onChanged: page == KaringPage.serverSelect
                          ? KaringScreen.applyServerSelection
                          : null,
                    )
                  : ListItem<void>(
                      leading: GlyphIcon(page.glyph),
                      title: Text(page.label(context)),
                    ),
            ),
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: context.sectionsTopPadding,
            bottom: 20 + context.bottomInset,
          ),
        ),
      ),
    );
  }
}
