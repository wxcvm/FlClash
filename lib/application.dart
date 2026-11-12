import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(List<ConnectivityResult> results)
  onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(child: ThemeManager(child: platformState)),
  );
}

// Ignore VPN-only interface events, but never discard a physical disconnect
// or reconnect just because the VPN adapter changed in the same event.
bool shouldRefreshAfterConnectivityChange(
  List<ConnectivityResult>? previous,
  List<ConnectivityResult> current,
) {
  final hasVpn = current.contains(ConnectivityResult.vpn);
  if (previous == null) {
    return !hasVpn;
  }
  final hadVpn = previous.contains(ConnectivityResult.vpn);
  if (hadVpn == hasVpn) {
    // A reconnect can report the same transport type (e.g. Wi-Fi).
    return true;
  }
  final before = previous
      .where((type) => type != ConnectivityResult.vpn)
      .toSet();
  final after = current.where((type) => type != ConnectivityResult.vpn).toSet();
  return !setEquals(before, after);
}

// An initial snapshot, a VPN-only change, and repeated reports of the same
// physical transports do not justify closing established connections.
Set<ConnectivityResult> physicalNetworks(List<ConnectivityResult> results) =>
    results
        .where(
          (type) =>
              type != ConnectivityResult.none && type != ConnectivityResult.vpn,
        )
        .toSet();

bool shouldRecoverDesktopNetwork(
  List<ConnectivityResult>? previous,
  List<ConnectivityResult> current,
) {
  if (previous == null) return false;
  final before = physicalNetworks(previous);
  final after = physicalNetworks(current);
  if (after.isEmpty) return false;
  if (before.isEmpty) return previous.contains(ConnectivityResult.none);
  return !setEquals(before, after);
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  List<ConnectivityResult>? _previousConnectivityResults;
  bool _pendingDesktopRecovery = false;
  int _desktopNetworkRevision = 0;
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    super.initState();
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      unawaited(window?.show());
      final message = currentAppLocalizations.createProfileFromUrlTip(url);
      final parts = message.split(url);
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: parts.first),
            TextSpan(
              text: url,
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ],
        ),
      );
      if (res != true) return;
      unawaited(
        ref.read(profilesActionProvider.notifier).addProfileFromLink(url),
      );
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      await ref.read(mitmModulesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    commonPrint.log('connectivityChanged ${results.toString()}');
    final dnsSync = systemDnsCoordinator?.resync() ?? Future<void>.value();
    unawaited(dnsSync);
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    final previous = _previousConnectivityResults;
    final changed = shouldRefreshAfterConnectivityChange(previous, results);
    _previousConnectivityResults = List.of(results);
    if (changed) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      ref
          .read(proxiesActionProvider.notifier)
          .onAutoSpeedNetworkChange(physicalNetworks(results).isNotEmpty);
      // Android's NetworkObserver tells the Core about a new network itself.
      if (system.isDesktop) {
        if (physicalNetworks(results).isEmpty) {
          _pendingDesktopRecovery = false;
        } else if (system.isWindows &&
            shouldRecoverDesktopNetwork(previous, results)) {
          _pendingDesktopRecovery = true;
        }
        final revision = ++_desktopNetworkRevision;
        debouncer.call(
          FunctionTag.networkChange,
          () async {
            await dnsSync;
            if (!mounted || revision != _desktopNetworkRevision) return;
            final recover = _pendingDesktopRecovery;
            _pendingDesktopRecovery = false;
            await ref
                .read(coreActionProvider.notifier)
                .reportNetworkChange(recover: recover);
          },
          duration: const Duration(milliseconds: 200),
        );
      }
    }
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        final textScale = themeProps.textScale;
        return PrismApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            return buildManagerStack(
              isDesktop: system.isDesktop,
              onConnectivityChanged: _handleConnectivityChanged,
              terminateSignals: _terminateSignals,
              child: child!,
            );
          },
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          textScale: textScale.enable ? textScale.scale : null,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          liquidGlass: switch (themeProps.liquidGlass) {
            LiquidGlassMode.none => null,
            LiquidGlassMode.ultra => LiquidGlassQuality.ultra,
            LiquidGlassMode.standard => LiquidGlassQuality.standard,
          },
          emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
          stackedBanners: !ref.watch(isMobileViewProvider),
          bannerTopInset: ref.watch(overlayTopOffsetProvider),
          remoteFocus: system.isTV,
          floatingKeyboard: app?.floatingKeyboard,
          onGenerateRoute: (settings) => HomeRoute(
            settings: settings,
            builder: (_) => KeyboardInsetHold(child: child!),
          ),
        );
      },
      child: const HomePage(),
    );
  }

  @override
  void dispose() {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}
