import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AndroidManager extends ConsumerStatefulWidget {
  final Widget child;

  const AndroidManager({super.key, required this.child});

  @override
  ConsumerState<AndroidManager> createState() => _AndroidContainerState();
}

class _AndroidContainerState extends ConsumerState<AndroidManager>
    with ServiceListener {
  @override
  void initState() {
    super.initState();
    ref.listenManual(appSettingProvider.select((state) => state.hidden), (
      prev,
      next,
    ) {
      app?.updateExcludeFromRecents(next);
    }, fireImmediately: true);
    ref.listenManual(loadedLocaleProvider, (prev, next) {
      if (prev != null && prev != next && !safeModeBuild) {
        app?.initShortcuts();
      }
    });
    ref.listenManual(sharedStateProvider, (prev, next) {
      if (prev != next) {
        debouncer.call(FunctionTag.saveSharedFile, () async {
          await preferences.saveShareState(next);
        }, duration: const Duration(seconds: 1));
        if (prev?.needSyncSharedState != next.needSyncSharedState) {
          service?.syncState(next.needSyncSharedState);
        }
      }
    });
    service?.addListener(this);
    service?.nativeStatus.addListener(_nativeStatusChanged);
    unawaited(_refreshNativeStatus());
    app?.onPackagesChanged = _reloadPackages;
  }

  bool _wasNative = false;
  int _nativeRevision = 0;

  Future<void> _refreshNativeStatus() async {
    try {
      await service?.getNativeStatus();
    } catch (error) {
      commonPrint.log('Android native status: $error', logLevel: LogLevel.debug);
    }
  }

  void _nativeStatusChanged() {
    if (!mounted) return;
    final status = service?.nativeStatus.value;
    if (status == null) return;
    final wasNative = _wasNative;
    _wasNative = status.ownsRuntime;
    if (!wasNative && !_wasNative) return;
    final revision = ++_nativeRevision;
    if (_wasNative) {
      ref.read(setupActionProvider.notifier).adoptAndroidNativeStatus(status);
      return;
    }
    if (status.state == 'STARTING' || status.state == 'STOPPING') {
      _wasNative = true;
      return;
    }
    ref.read(setupActionProvider.notifier).adoptAndroidNativeStatus(status);
    unawaited(_restoreMihomoView(revision));
  }

  Future<void> _restoreMihomoView(int revision) async {
    try {
      await ref.read(coreActionProvider.notifier).initCore();
      if (!mounted || revision != _nativeRevision || service?.nativeOwnsRuntime == true) return;
      if (ref.read(appSettingProvider).openLogs) {
        await ref.read(coreHandlerProvider).startLog();
      }
    } catch (error) {
      commonPrint.log('Restore Mihomo view: $error', logLevel: coreFailureLogLevel(error));
    }
  }

  /// A reload reads every installed app's label, and a round of store updates
  /// reports each app on its own.
  void _reloadPackages() {
    if (ref.read(packagesProvider).isEmpty) {
      return;
    }
    debouncer.call(FunctionTag.reloadPackages, () async {
      if (mounted) {
        await ref.read(systemActionProvider.notifier).getPackages();
      }
    }, duration: const Duration(seconds: 2));
  }

  @override
  void dispose() {
    debouncer.cancel(FunctionTag.reloadPackages);
    if (app?.onPackagesChanged == _reloadPackages) {
      app?.onPackagesChanged = null;
    }
    service?.nativeStatus.removeListener(_nativeStatusChanged);
    service?.removeListener(this);
    super.dispose();
  }

  @override
  void onServiceEvent(CoreEvent event) {
    if (service?.nativeOwnsRuntime == true) return;
    coreEventManager.sendEvent(event);
    super.onServiceEvent(event);
  }

  @override
  void onServiceStopped() {
    if (service?.nativeOwnsRuntime == true || _wasNative) {
      unawaited(_refreshNativeStatus());
      return;
    }
    unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
    super.onServiceStopped();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
