part of '../action.dart';

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _requestedRestartRevision = 0;
  Future<bool>? _restartOperation;
  int _networkEventRevision = 0;
  int _networkVerifications = 0;
  DateTime? _lastWatchdogRefresh;

  @override
  void build() {
    ref.listen(isStartProvider, (_, _) => _networkEventRevision++);
    ref.listen(suspendProvider, (_, _) => _networkEventRevision++);
    ref.listen(coreStatusProvider, (_, _) => _networkEventRevision++);
    ref.listen(currentProfileIdProvider, (_, _) => _networkEventRevision++);
    if (system.isWindows) {
      final timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (_networkVerifications != 0 ||
            !ref.read(isStartProvider) ||
            ref.read(suspendProvider) ||
            nativeCoreRuntime.blocksMihomoStart) {
          return;
        }
        unawaited(verifyNetworkAfterResume(watchdog: true));
      });
      ref.onDispose(timer.cancel);
    }
  }

  Future<void> initCore() async {
    if (service?.nativeOwnsRuntime == true) return;
    final isInit = await _core.isInit;

    final version = ref.read(versionProvider);
    if (!isInit) {
      await _core.init(version);
    } else {
      await ref.read(proxiesActionProvider.notifier).updateGroups();
      await ref.read(providersProvider.notifier).syncProviders();
    }
  }

  Future<void> startCore() async {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    try {
      final result = await startLifecycle();
      await _applyLifecycleResult(result);
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      dialogs.showBanner(error.toString(), level: BannerLevel.error);
    }
  }

  @protected
  Future<CoreLifecycleResult> startLifecycle() {
    return _core.start();
  }

  @protected
  Future<CoreLifecycleResult> restartLifecycle() {
    return _core.restart();
  }

  // Nothing in lib/ calls CoreController.stop(); only close() (app exit)
  // supersedes a start/restart. statusFirst lets onCrash catch a crash
  // during initCore itself (it early-returns unless status is connected).
  Future<bool> _applyLifecycleResult(
    CoreLifecycleResult result, {
    bool statusFirst = false,
  }) async {
    if (result.outcome == CoreLifecycleOutcome.superseded) {
      return false;
    }
    if (statusFirst) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await initCore();
    } else {
      await initCore();
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    }
    if (mitmFeature && ref.read(patchClashConfigProvider).mitm.enable) {
      unawaited(ref.read(mitmTrustStateProvider.notifier).refresh());
    }
    return true;
  }

  Future<void> closeConnection(String id) async {
    await _core.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await _core.closeConnections();
  }

  Future<void> reportNetworkChange({bool recover = false}) async {
    _networkEventRevision++;
    if (service?.nativeOwnsRuntime == true) return;
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    try {
      if (recover) {
        await _core.recoverNetwork();
      } else {
        await _core.reportNetworkChange();
      }
    } catch (error) {
      commonPrint.log(
        'reportNetworkChange error: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  /// Wake and same-transport reconnects do not prove that connections are
  /// broken. Reuse the core's bounded route health probe before resetting.
  Future<void> verifyNetworkAfterResume({
    bool refreshPath = false,
    bool watchdog = false,
  }) async {
    final revision = ++_networkEventRevision;
    final route = ref.read(routeTrackerProvider);
    bool current() =>
        ref.mounted &&
        revision == _networkEventRevision &&
        ref.read(isStartProvider) &&
        !ref.read(suspendProvider) &&
        ref.read(coreStatusProvider) == CoreStatus.connected &&
        ref.read(routeTrackerProvider).hostEpoch == route.hostEpoch &&
        service?.nativeOwnsRuntime != true &&
        !(system.isDesktop && nativeCoreRuntime.blocksMihomoStart);
    if (!current()) return;
    if (watchdog) {
      final last = _lastWatchdogRefresh;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 2)) {
        return;
      }
    }
    _networkVerifications++;
    try {
      final recover = await verifyDesktopNetwork(
        check: _core.checkNetworkHealth,
        read: _core.getNetworkHealth,
        isCurrent: current,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        refreshPath: refreshPath ? _core.reportNetworkChange : null,
      );
      if (recover && current()) {
        if (watchdog) {
          // One endpoint is not proof that all traffic is broken. Refresh
          // resolver transports without closing live connections.
          _lastWatchdogRefresh = DateTime.now();
          await reportNetworkChange();
        } else {
          await reportNetworkChange(recover: true);
        }
      }
    } catch (error) {
      commonPrint.log(
        'Wake network verification failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      _networkVerifications--;
    }
  }

  Future<void> forceGc() async {
    await _core.forceGc();
  }

  Future<void> crash() async {
    await _core.crash();
  }

  Future<bool> restartCore() {
    if (service?.nativeOwnsRuntime == true) return Future.value(false);
    _requestedRestartRevision++;
    final activeOperation = _restartOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    final operation = _runRestartWorker();
    _restartOperation = operation;
    return operation;
  }

  Future<bool> _runRestartWorker() async {
    try {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      final result = await restartLifecycle();
      if (!await _applyLifecycleResult(result, statusFirst: true)) {
        return false;
      }

      var appliedRevision = 0;
      var applied = true;
      while (appliedRevision < _requestedRestartRevision) {
        final revision = _requestedRestartRevision;
        if (ref.read(isStartProvider)) {
          applied = await ref
              .read(setupActionProvider.notifier)
              .setRunning(true, initialize: true);
        } else {
          applied = await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);
        }
        appliedRevision = revision;
      }
      return applied;
    } catch (_) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      rethrow;
    } finally {
      _restartOperation = null;
    }
  }
}
