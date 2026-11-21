import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/karing/navigation_target.dart';
import 'package:fl_clash/features/karing/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/clash_api.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:karing/screens/diversion_rules_screen.dart';
import 'package:karing/screens/dns_settings_screen.dart';
import 'package:karing/screens/group_helper.dart';
import 'package:karing/screens/net_connections_screen.dart';
import 'package:karing/screens/perapp_android_screen.dart';
import 'package:karing/screens/perapp_macos_screen.dart';
import 'package:karing/screens/server_select_screen.dart';
import 'package:karing/screens/text_to_qrcode_screen.dart';
import 'package:karing/screens/urltest_group_custom_screen.dart';

final _connectionsUrlProvider = FutureProvider.autoDispose<String>((ref) async {
  await ref.watch(karingModuleProvider.future);
  return ClashApi.getConnectionsUrl(
    SettingManager.getConfig().proxy.controlPort,
  );
});

class KaringScreen extends ConsumerWidget {
  const KaringScreen({super.key, required this.page});

  final KaringPage page;

  static void applyServerSelection(Object? result) {
    if (result is! ProxyConfig) return;
    ServerManager.addRecent(result);
    unawaited(ServerManager.saveUse());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!page.isSupported) {
      return Scaffold(
        title: page.label(context),
        body: const SizedBox.shrink(),
      );
    }
    return ref
        .watch(karingModuleProvider)
        .when(
          data: (_) => switch (page) {
            KaringPage.diversionRules => const DiversionRulesScreen(),
            KaringPage.dnsSettings => _buildDns(context),
            KaringPage.backupSync => const _BackupSyncView(),
            KaringPage.netConnections =>
              ref
                  .watch(_connectionsUrlProvider)
                  .when(
                    data: (url) => NetConnectionsScreen(
                      connectionsUrl: url,
                      checkStarted: true,
                    ),
                    loading: () => _buildStatus(context),
                    error: (_, _) => _buildStatus(context, failed: true),
                  ),
            KaringPage.serverSelect => ServerSelectScreen(
              singleSelect: ServerSelectScreenSingleSelectedOption(
                selectedServer:
                    ServerManager.getMostRecent() ?? ServerManager.getUrltest(),
                showUrltestGroup: true,
              ),
              multiSelect: null,
            ),
            KaringPage.urltestGroups => const UrlTestGroupCustomScreen(),
            KaringPage.qrcodeTool => const TextToQrCodeScreen(),
            KaringPage.perApp =>
              Platform.isAndroid
                  ? const PerAppAndroidScreen()
                  : const PerAppMacosScreen(),
          },
          loading: () => _buildStatus(context),
          error: (_, _) => _buildStatus(context, failed: true),
        );
  }

  Widget _buildStatus(BuildContext context, {bool failed = false}) => Scaffold(
    title: page.label(context),
    body: Center(
      child: failed
          ? Text(context.appLocalizations.initFailed)
          : const ActivityIndicator(),
    ),
  );

  Widget _buildDns(BuildContext context) {
    final config = SettingManager.getConfig();
    final tunMode = config.tun.enable;
    final servers = config.dns.getDirectDns(
      config.regionCode.toLowerCase(),
      tunMode,
    );
    return DnsSettingsScreen(
      title: page.label(context),
      servers: servers.toSet(),
      disabled: const <String>{},
      tunMode: tunMode,
      maxServers: SettingConfigItemDNS.kDNSServerMax,
      onChanged: (server, selected) {
        config.dns.addOrRemoveDirectDns(server, selected);
        SettingManager.setDirty(true);
        SettingManager.saveConfig();
      },
    );
  }
}

class _BackupSyncView extends StatelessWidget {
  const _BackupSyncView();

  @override
  Widget build(BuildContext context) {
    final meta = Translations.of(context).meta;
    return Scaffold(
      title: meta.backupAndSync,
      body: Builder(
        builder: (context) => PrismListView(
          itemCount: 1,
          itemBuilder: (_, _) => generateSection(
            items: [
              if (Platform.isIOS || Platform.isMacOS)
                ListItem<void>(
                  title: Text(meta.iCloud),
                  onTap: () => GroupHelper.onTapiCloud(context),
                ),
              ListItem<void>(
                title: Text(meta.webdav),
                onTap: () => GroupHelper.onTapWebdav(context),
              ),
              ListItem<void>(
                title: Text(meta.lanSync),
                onTap: () => GroupHelper.onTapLanSync(context),
              ),
              ListItem<void>(
                title: Text(meta.importAndExport),
                onTap: () => GroupHelper.onTapImportExport(context),
              ),
              ListItem<void>(
                title: Text(meta.autoBackup),
                onTap: () => GroupHelper.onTapAutoBackup(context),
              ),
            ],
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
