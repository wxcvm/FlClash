part of '../action.dart';

/// Automatic selection keeps a working incumbent unless the contender is
/// at least 20% faster. An explicit fastest-node request uses the top rate.
/// Rates are conservative lower-of-two samples in bytes per second.
String? chooseDownloadSpeedWinner(
  Map<String, int> rates,
  String incumbent, {
  bool automatic = true,
}) {
  String? winner;
  var best = 0;
  for (final entry in rates.entries) {
    if (entry.value > best) {
      winner = entry.key;
      best = entry.value;
    }
  }
  if (winner == null) {
    return null;
  }
  final current = rates[incumbent] ?? 0;
  if (automatic && current > 0 && best * 5 < current * 6) {
    return incumbent;
  }
  return winner;
}

/// Retest the incumbent and known fast nodes, leaving room to explore.
List<String> automaticSpeedCandidates(
  List<String> names,
  String incumbent,
  Map<String, int> rates,
  int cursor,
) {
  if (names.isEmpty) {
    return [];
  }
  final candidates = <String>{if (names.contains(incumbent)) incumbent};
  final known = names.where((name) => (rates[name] ?? 0) > 0).toList()
    ..sort((a, b) => rates[b]!.compareTo(rates[a]!));
  candidates.addAll(known.where((name) => !candidates.contains(name)).take(2));
  for (var i = 0; i < names.length && candidates.length < 4; i++) {
    candidates.add(names[(cursor + i) % names.length]);
  }
  return candidates.toList();
}

class _DelayTestTarget {
  const _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
  });

  final String proxyName;
  final String testUrl;
  final String key;
}

typedef _DelayTestBatch = ({List<Proxy> proxies, String? testUrl});

class _DelayTestJob {
  _DelayTestJob(Iterable<String> keys, this.timeout, this.generation)
    : held = keys.toSet();

  final Set<String> held;
  final Duration timeout;
  final int generation;
  final Set<String> startedOnDispatch = {};
  bool cancelled = false;
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);
  final TaskPool _speedTestPool = TaskPool(1);
  int _speedTestGeneration = 0;
  final Set<String> _speedTestingGroups = {};
  Timer? _autoSpeedTimer;
  bool _autoSpeedOnline = true;
  bool _autoSpeedRunning = false;
  int _autoSpeedCursor = 0;
  final _nodeHealth = NodeHealthHistory();

  final List<_DelayTestJob> _delayTestJobs = [];
  final Map<String, int> _latestDelayTestGeneration = {};
  int _delayTestGeneration = 0;

  final List<Delay> _bufferedDelays = [];

  final List<String> _bufferedStarts = [];

  final List<String> _bufferedFinishes = [];

  Timer? _delayFlushTimer;

  final Map<String, String> _pendingSelectedRollback = {};

  @override
  void build() {
    ref.onDispose(() {
      _delayFlushTimer?.cancel();
      _autoSpeedTimer?.cancel();
    });
    ref.listen(currentProfileIdProvider, (previous, next) {
      if (previous != next) {
        _speedTestGeneration++;
        _autoSpeedTimer?.cancel();
        _autoSpeedCursor = 0;
        _nodeHealth.reset();
      }
    });
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
        _speedTestGeneration++;
        _nodeHealth.reset();
      }
      _scheduleAutoSpeed();
    });
    ref.listen(isStartProvider, (_, _) => _scheduleAutoSpeed());
    ref.listen(appVisibleProvider, (_, visible) {
      if (system.isAndroid && !visible) {
        _speedTestGeneration++;
        if (_speedTestPool.activeCount > 0 &&
            ref.read(coreStatusProvider) == CoreStatus.connected) {
          unawaited(_core.stopSpeedTests());
        }
      }
      _scheduleAutoSpeed();
    });
    ref.listen(suspendProvider, (_, _) => _scheduleAutoSpeed());
  }

  bool get _autoSpeedReady =>
      service?.nativeOwnsRuntime != true &&
      _autoSpeedOnline &&
      ref.read(downloadSpeedAutoGroupProvider) != null &&
      (system.isDesktop || ref.read(appVisibleProvider)) &&
      !ref.read(suspendProvider) &&
      ref.read(isStartProvider) &&
      ref.read(coreStatusProvider) == CoreStatus.connected;

  void setDownloadSpeedAutoGroup(String? name) {
    ref.read(downloadSpeedAutoGroupProvider.notifier).select(name);
    _autoSpeedCursor = 0;
    _nodeHealth.reset();
    _scheduleAutoSpeed();
  }

  void onAutoSpeedNetworkChange(bool online) {
    _autoSpeedOnline = online;
    _nodeHealth.reset(keepOptimizationBudget: true);
    _scheduleAutoSpeed();
  }

  void _scheduleAutoSpeed({Duration delay = const Duration(seconds: 2)}) {
    _autoSpeedTimer?.cancel();
    if (!_autoSpeedReady) {
      return;
    }
    _autoSpeedTimer = Timer(delay, () => unawaited(_runAutoSpeed()));
  }

  Future<void> _runAutoSpeed() async {
    if (!_autoSpeedReady) {
      return;
    }
    if (_autoSpeedRunning ||
        _speedTestingGroups.isNotEmpty ||
        _speedTestPool.activeCount > 0) {
      _scheduleAutoSpeed(delay: const Duration(seconds: 15));
      return;
    }
    final name = ref.read(downloadSpeedAutoGroupProvider);
    final group = ref.read(groupsProvider).getGroup(name ?? '');
    if (group == null) {
      _scheduleAutoSpeed(delay: const Duration(seconds: 15));
      return;
    }
    if (group.type != GroupType.URLTest) {
      return;
    }
    _autoSpeedRunning = true;
    final profile = ref.read(currentProfileIdProvider);
    final epoch = ref.read(routeTrackerProvider).hostEpoch;
    final generation = _speedTestGeneration;
    final selection = _currentSelectedName(group.name);
    final incumbent = group.getCurrentSelectedName(selection);
    bool isCurrent() =>
        ref.mounted &&
        _autoSpeedReady &&
        ref.read(downloadSpeedAutoGroupProvider) == group.name &&
        ref.read(currentProfileIdProvider) == profile &&
        ref.read(routeTrackerProvider).hostEpoch == epoch &&
        _speedTestGeneration == generation &&
        _currentSelectedName(group.name) == selection;
    try {
      if (incumbent.isEmpty ||
          reservedCustomProxyNames.contains(incumbent) ||
          isSubscriptionInfoProxyName(incumbent)) {
        return;
      }
      if (!await _networkAllowsAutoSelection(isCurrent)) return;
      final delay = await _probeAutoNode(group, incumbent);
      if (!isCurrent()) return;
      final decision = _nodeHealth.record(incumbent, delay, DateTime.now());
      if (decision == NodeHealthDecision.wait) return;
      if (decision == NodeHealthDecision.failover) {
        if (!await _networkAllowsAutoSelection(
          isCurrent,
          requireRecent: true,
        )) {
          return;
        }
        _nodeHealth.markOptimization(DateTime.now());
        await _recoverAutoNode(group, incumbent, isCurrent);
      } else {
        _nodeHealth.markOptimization(DateTime.now());
        await selectByDownloadSpeed(group.name, automatic: true);
      }
    } finally {
      _autoSpeedRunning = false;
      if (ref.mounted && _autoSpeedTimer?.isActive != true) {
        _scheduleAutoSpeed(delay: const Duration(seconds: 30));
      }
    }
  }

  // A shared DNS failure can make every node look dead. It must not
  // authorize a switch. Refresh stale diagnostics without changing routes.
  Future<bool> _networkAllowsAutoSelection(
    bool Function() isCurrent, {
    bool requireRecent = false,
  }) async {
    if (!isCurrent()) return false;
    try {
      final health = await _core.getNetworkHealth();
      if (!isCurrent()) return false;
      final gate = networkHealthGate(
        health,
        DateTime.now(),
        requireRecent: requireRecent,
      );
      if (health['dns'] == 'failed') {
        _nodeHealth.reset(keepOptimizationBudget: true);
      }
      if (gate == NetworkHealthGate.refresh) {
        await _core.checkNetworkHealth();
      }
      return gate == NetworkHealthGate.allow && isCurrent();
    } catch (error) {
      commonPrint.log(
        'Automatic selection deferred: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return false;
    }
  }

  Future<int?> _probeAutoNode(Group group, String name) async {
    try {
      final result = await _core.testDelay(
        TestDelayParams(
          proxyName: name,
          testUrl: ref.read(realTestUrlProvider(group.testUrl)),
          timeout: ref.read(appSettingProvider).delayTestTimeout,
        ),
      );
      return result.value;
    } catch (error) {
      commonPrint.log(
        'Automatic node health check failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  // Recovery does not depend on the throughput endpoint. Prefer known fast
  // alternatives, but require two successful lightweight probes.
  Future<void> _recoverAutoNode(
    Group group,
    String incumbent,
    bool Function() isCurrent,
  ) async {
    final names = group.all
        .map((proxy) => proxy.name)
        .where(
          (name) =>
              !reservedCustomProxyNames.contains(name) &&
              !isSubscriptionInfoProxyName(name),
        )
        .toSet()
        .toList();
    final candidates = automaticSpeedCandidates(
      names,
      incumbent,
      ref.read(downloadSpeedSortSnapshotProvider),
      _autoSpeedCursor++,
    ).where((name) => name != incumbent);
    for (final name in candidates) {
      if (!isCurrent()) return;
      final first = await _probeAutoNode(group, name);
      if (!isCurrent()) return;
      if (first == null || first <= 0) continue;
      final second = await _probeAutoNode(group, name);
      if (!isCurrent()) return;
      if (second == null || second <= 0) continue;
      final recovered = await _probeAutoNode(group, incumbent);
      if (!isCurrent() || recovered == null || recovered == 0) return;
      if (recovered > 0) return;
      final current = ref.read(groupsProvider).getGroup(group.name);
      if (current == null || !current.all.any((proxy) => proxy.name == name)) {
        return;
      }
      if (!await _networkAllowsAutoSelection(isCurrent, requireRecent: true)) {
        return;
      }
      if (await _selectVerifiedSpeed(
        group.name,
        name,
        isCurrent,
        automatic: true,
      )) {
        return;
      }
    }
  }

  void syncAndroidNativeOwnership() {
    if (service?.nativeOwnsRuntime == true) {
      cancelDelayTests();
      _speedTestGeneration++;
      _autoSpeedTimer?.cancel();
      debouncer.cancel(FunctionTag.updateGroups);
    } else {
      _scheduleAutoSpeed();
    }
  }

  void cancelDelayTests() {
    for (final job in _delayTestJobs) {
      job.cancelled = true;
      job.held.clear();
    }
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    _bufferedDelays.clear();
    _bufferedStarts.clear();
    _bufferedFinishes.clear();
    _latestDelayTestGeneration.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
  }

  void _scheduleDelayFlush() {
    _delayFlushTimer ??= Timer(renderThrottleDuration, _flushDelayResults);
  }

  void _flushDelayResults() {
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    if (_bufferedDelays.isNotEmpty) {
      final delays = List.of(_bufferedDelays);
      _bufferedDelays.clear();
      ref.read(delayDataSourceProvider.notifier).setDelays(delays);
    }
    if (_bufferedStarts.isNotEmpty || _bufferedFinishes.isNotEmpty) {
      final started = List.of(_bufferedStarts);
      final finished = List.of(_bufferedFinishes);
      _bufferedStarts.clear();
      _bufferedFinishes.clear();
      ref
          .read(pendingDelayTestsProvider.notifier)
          .apply(started: started, finished: finished);
    }
  }

  void updateGroupsDebounce([Duration? duration]) {
    if (service?.nativeOwnsRuntime == true) return;
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    if (ref.read(downloadSpeedAutoGroupProvider) == groupName) {
      setDownloadSpeedAutoGroup(null);
    }
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => _currentSelectedName(groupName),
    );
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    debouncer.call((FunctionTag.changeProxy, groupName), (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    if (service?.nativeOwnsRuntime == true) return;
    final generation = _speedTestGeneration;
    try {
      final groups = await retry<List<Group>>(
        task: () async {
          if (service?.nativeOwnsRuntime == true) return [];
          final sortType = ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = ref.read(delayDataSourceProvider);
          final testUrl = ref.read(
            patchClashConfigProvider.select((state) => state.testUrl),
          );
          final selectedMap = ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          );
          try {
            return await _core.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return [];
          }
        },
        retryIf: (res) =>
            service?.nativeOwnsRuntime != true &&
            generation == _speedTestGeneration &&
            res.isEmpty,
      );
      if (service?.nativeOwnsRuntime != true &&
          generation == _speedTestGeneration) {
        ref.read(groupsProvider.notifier).value = groups;
      }
    } catch (e) {
      // The Core failure path already runs inside the retry task above; a
      // throw here only means ref.read hit a disposed container or the
      // groupsProvider write itself failed.
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    _bufferedDelays.add(delay);
    _scheduleDelayFlush();
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final rollbackName =
        _pendingSelectedRollback.remove(groupName) ??
        _currentSelectedName(groupName);
    profilesAction.updateCurrentSelectedMap(groupName, proxyName);
    final ChangeProxyResult result;
    try {
      result = await _core.changeProxy(
        ChangeProxyParams(groupName: groupName, proxyName: proxyName),
      );
      if (result.message.isNotEmpty) {
        throw MessageException(result.message);
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      profilesAction.updateCurrentSelectedMap(groupName, rollbackName);
      dialogs.showBanner(
        currentAppLocalizations.changeProxyFailedTip,
        level: BannerLevel.error,
      );
      return;
    }
    if (result.changed) {
      await _refreshSelectedConnections(groupName, proxyName);
    }
  }

  Future<void> _refreshSelectedConnections(
    String groupName,
    String proxyName,
  ) async {
    try {
      if (ref.read(appSettingProvider).closeConnections) {
        await _core.closeConnections();
      } else {
        await _core.resetConnections();
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) connection reset failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<void> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final clashProvidersAction = ref.read(
        clashProvidersActionProvider.notifier,
      );
      final ruleSet = await clashProvidersAction.remoteProviderOf(provider);
      if (ruleSet != null && !await clashProvidersAction.syncRemote(ruleSet)) {
        return;
      }
      await _core.updateExternalProvider(provider.name);
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> addToLocalProxies(String proxyName) async {
    final appLocalizations = currentAppLocalizations;
    final definition = await _core.getProxyDefinition(proxyName);
    if (definition == null) {
      throw MessageException(
        appLocalizations.customIssueMissingProxies(proxyName),
      );
    }
    final (proxies, groupNames) = await (
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names().get(),
    ).wait;
    final (:name, :added) = importProxy(
      definition,
      existing: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    if (added == null) {
      dialogs.showBanner(appLocalizations.alreadyInLocalProxies(name));
      return;
    }
    final order = indexing.generateKeyBetween(
      proxies.map((proxy) => proxy.order).nonNulls.lastOrNull,
      null,
    );
    await database.customProxies.put(
      CustomProxy.fromDefinition(added).copyWith(order: order).toCompanion(),
    );
    dialogs.showBanner(appLocalizations.addedToLocalProxies(name));
  }

  /// Measure real download throughput, then recheck the fastest three.
  Future<void> selectByDownloadSpeed(
    String groupName, {
    bool selectWinner = true,
    bool matchSearch = false,
    bool automatic = false,
  }) async {
    if (!_speedTestingGroups.add(groupName)) {
      return;
    }
    ref.read(downloadSpeedTestingGroupsProvider.notifier).start(groupName);
    try {
      if (ref.read(coreStatusProvider) != CoreStatus.connected) {
        return;
      }
      final group = ref.read(groupsProvider).getGroup(groupName);
      if (group == null) {
        return;
      }
      if (selectWinner &&
          group.type != GroupType.Selector &&
          group.type != GroupType.URLTest) {
        dialogs.showBanner('此策略组不支持固定下载速度优选节点', level: BannerLevel.warning);
        return;
      }
      final initialProfileId = ref.read(currentProfileIdProvider);
      final initialSelection = ref
          .read(currentProfileProvider)
          ?.selectedMap[groupName];
      final initialHostEpoch = ref.read(routeTrackerProvider).hostEpoch;
      final initialGeneration = _speedTestGeneration;
      final incumbent = group.getCurrentSelectedName(initialSelection ?? '');

      bool isCurrent() =>
          ref.mounted &&
          ref.read(coreStatusProvider) == CoreStatus.connected &&
          _speedTestGeneration == initialGeneration &&
          ref.read(routeTrackerProvider).hostEpoch == initialHostEpoch &&
          ref.read(currentProfileIdProvider) == initialProfileId &&
          ref.read(currentProfileProvider)?.selectedMap[groupName] ==
              initialSelection &&
          (!automatic ||
              (_autoSpeedReady &&
                  ref.read(downloadSpeedAutoGroupProvider) == groupName));
      // Test the actual group members, not resolved leaves of nested groups.
      // A resolved leaf may not be a selectable member of this group.
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      final names = group.all
          .whereMatches(query, (proxy) => proxy.searchFields)
          .map((proxy) => proxy.name)
          .where(
            (name) =>
                !reservedCustomProxyNames.contains(name) &&
                !isSubscriptionInfoProxyName(name),
          )
          .toSet()
          .toList();
      final candidates = automatic
          ? automaticSpeedCandidates(
              names,
              incumbent,
              ref.read(downloadSpeedSortSnapshotProvider),
              _autoSpeedCursor++,
            )
          : names;
      if (candidates.isEmpty) {
        return;
      }

      Future<int> measure(String name) =>
          _measureDownloadSpeed(name, isCurrent);

      final first = <String, int>{};
      for (final name in candidates) {
        if (!isCurrent()) return;
        final speed = await _speedTestPool.run(() => measure(name));
        if (speed > 0) {
          first[name] = speed;
        }
      }

      if (!selectWinner) {
        return;
      }

      final ranked = first.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (!isCurrent()) {
        return;
      }
      final finalists = {
        for (final candidate in ranked.take(3)) candidate.key,
        if (first.containsKey(incumbent)) incumbent,
      };
      final stable = <String, int>{};
      for (final name in finalists) {
        if (!isCurrent()) return;
        final second = await _speedTestPool.run(() => measure(name));
        if (!isCurrent()) return;
        final initial = first[name]!;
        if (second > 0) {
          stable[name] = second < initial ? second : initial;
          ref
              .read(downloadSpeedResultsProvider.notifier)
              .finish(name, stable[name]!);
        }
      }

      if (!isCurrent()) {
        return;
      }
      if (stable.isEmpty) {
        if (!automatic) {
          dialogs.showBanner(
            '下载测速失败：没有节点完成有效的数据下载',
            level: BannerLevel.warning,
          );
        }
        return;
      }
      final currentGroup = ref.read(groupsProvider).getGroup(groupName);
      if (currentGroup == null) {
        return;
      }
      final current = currentGroup.getCurrentSelectedName(
        initialSelection ?? '',
      );
      // A failed throughput sample alone is not proof that a working node
      // is dead. Only the health monitor can authorize that failover.
      if (automatic && !stable.containsKey(current)) {
        return;
      }
      final remaining = {
        for (final proxy in currentGroup.all)
          if (stable.containsKey(proxy.name)) proxy.name: stable[proxy.name]!,
      };
      while (remaining.isNotEmpty && isCurrent()) {
        final winner = chooseDownloadSpeedWinner(
          remaining,
          current,
          automatic: automatic,
        );
        if (winner == null || (automatic && winner == current)) {
          return;
        }
        if (await _selectVerifiedSpeed(
          groupName,
          winner,
          isCurrent,
          automatic: automatic,
        )) {
          return;
        }
        // A healthy incumbent must not be discarded merely because its
        // health-check endpoint failed during a speed optimization.
        if (winner == current) {
          return;
        }
        remaining.remove(winner);
      }
      if (isCurrent() && !automatic) {
        dialogs.showBanner('下载测速完成，但没有节点通过策略组健康检查', level: BannerLevel.warning);
      }
    } finally {
      _speedTestingGroups.remove(groupName);
      if (ref.mounted) {
        ref.read(downloadSpeedTestingGroupsProvider.notifier).stop(groupName);
        _publishDownloadSpeedSort();
      }
    }
  }

  Future<bool> _selectVerifiedSpeed(
    String groupName,
    String name,
    bool Function() isCurrent, {
    required bool automatic,
  }) async {
    if (!isCurrent()) {
      return false;
    }
    try {
      if (automatic && !await _networkAllowsAutoSelection(isCurrent)) {
        return false;
      }
      final result = await _core.selectSpeedProxy(
        ChangeProxyParams(groupName: groupName, proxyName: name),
      );
      if (!isCurrent()) {
        return false;
      }
      if (result.message.isNotEmpty) {
        commonPrint.log('Speed selection rejected: ${result.message}');
        return false;
      }
      // An automatic choice is runtime-only. Never overwrite the user's
      // saved preference. One-click manual selection still persists.
      if (!automatic) {
        ref
            .read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(groupName, name);
        if (result.changed) {
          await _refreshSelectedConnections(groupName, name);
        }
      }
      await updateGroups();
      return true;
    } catch (error) {
      commonPrint.log(
        'Verified speed selection failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return false;
    }
  }

  void _publishDownloadSpeedSort() {
    if (_speedTestingGroups.isNotEmpty) {
      return;
    }
    ref
        .read(downloadSpeedSortSnapshotProvider.notifier)
        .publish(ref.read(downloadSpeedResultsProvider));
  }

  Future<int> _measureDownloadSpeed(
    String name,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent() || (system.isAndroid && !ref.read(appVisibleProvider))) {
      return 0;
    }
    final results = ref.read(downloadSpeedResultsProvider.notifier);
    results.start(name);
    var speed = 0;
    try {
      final result = await _core.testSpeed(name);
      final value = result['bytes-per-second'];
      if (value is num) {
        speed = value.toInt();
      }
    } catch (error) {
      commonPrint.log(
        'Download speed test failed for $name: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
    if (!isCurrent()) {
      if (ref.mounted) {
        ref.read(downloadSpeedResultsProvider.notifier).discardRunning(name);
      }
      return 0;
    }
    ref.read(downloadSpeedResultsProvider.notifier).finish(name, speed);
    return speed;
  }

  Future<void> testProxyMetrics(Proxy proxy, [String? testUrl]) =>
      _testProxyMetrics(proxy, testUrl: testUrl);

  Future<void> testProxyDownloadSpeed(Proxy proxy) =>
      _testProxyMetrics(proxy, testDelay: false);

  Future<void> _testProxyMetrics(
    Proxy proxy, {
    String? testUrl,
    bool testDelay = true,
  }) async {
    if (isSubscriptionInfoProxyName(proxy.name)) return;
    final epoch = ref.read(routeTrackerProvider).hostEpoch;
    final profile = ref.read(currentProfileIdProvider);
    final generation = _speedTestGeneration;
    bool isCurrent() =>
        ref.mounted &&
        ref.read(coreStatusProvider) == CoreStatus.connected &&
        _speedTestGeneration == generation &&
        ref.read(routeTrackerProvider).hostEpoch == epoch &&
        ref.read(currentProfileIdProvider) == profile;
    if (testDelay) await proxyDelayTest(proxy, testUrl);
    if (!isCurrent() || reservedCustomProxyNames.contains(proxy.name)) {
      return;
    }
    await _speedTestPool.run(
      () => _measureDownloadSpeed(proxy.name, isCurrent),
    );
    if (isCurrent()) {
      _publishDownloadSpeedSort();
    }
  }

  Future<void> testPageGroupMetrics(String groupName) async {
    final epoch = ref.read(routeTrackerProvider).hostEpoch;
    final profile = ref.read(currentProfileIdProvider);
    final generation = _speedTestGeneration;
    await delayTestPageGroup(groupName);
    if (!ref.mounted ||
        _speedTestGeneration != generation ||
        ref.read(routeTrackerProvider).hostEpoch != epoch ||
        ref.read(currentProfileIdProvider) != profile) {
      return;
    }
    await selectByDownloadSpeed(
      groupName,
      selectWinner: false,
      matchSearch: true,
    );
  }

  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
    return _runDelayTests([
      (proxies: [proxy], testUrl: testUrl),
    ]);
  }

  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    await _runDelayTests([(proxies: proxies, testUrl: testUrl)]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    await _runDelayTests([
      for (final group in groups) (proxies: group.all, testUrl: group.testUrl),
    ]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestPageGroup(
    String groupName, {
    bool matchSearch = true,
  }) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      return;
    }
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    if (!testing.start(groupName)) {
      return;
    }
    try {
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      await delayTest(
        group.all.whereMatches(query, (proxy) => proxy.searchFields).toList(),
        group.testUrl,
      );
    } finally {
      testing.stop(groupName);
    }
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<_DelayTestBatch> batches,
  ) {
    final groups = ref.read(groupsProvider);
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final seen = <String>{};
    final targets = <_DelayTestTarget>[];
    for (final batch in batches) {
      final fallbackTestUrl = ref.read(realTestUrlProvider(batch.testUrl));
      for (final proxy in batch.proxies) {
        final state = computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          selectedMap: selectedMap,
        );
        if (state.proxyName.isEmpty ||
            isSubscriptionInfoProxyName(state.proxyName)) {
          continue;
        }
        final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
        final key = delayTestKey(currentTestUrl, state.proxyName);
        if (!seen.add(key)) {
          continue;
        }
        targets.add(
          _DelayTestTarget(
            proxyName: state.proxyName,
            testUrl: currentTestUrl,
            key: key,
          ),
        );
      }
    }
    return targets;
  }

  Future<void> _runDelayTests(List<_DelayTestBatch> batches) async {
    final targets = _resolveDelayTestTargets(batches);
    if (targets.isEmpty) {
      return;
    }
    final pending = ref.read(pendingDelayTestsProvider.notifier);
    final generation = ++_delayTestGeneration;
    for (final target in targets) {
      _latestDelayTestGeneration[target.key] = generation;
    }
    final job = _DelayTestJob(
      targets.map((target) => target.key),
      Duration(milliseconds: ref.read(appSettingProvider).delayTestTimeout),
      generation,
    );
    _delayTestJobs.add(job);
    // TaskPool.run starts a task synchronously while it has an idle slot.
    job.startedOnDispatch.addAll(
      targets.take(_delayTestPool.idleSlots).map((target) => target.key),
    );
    pending.apply(acquired: job.held, started: job.startedOnDispatch);
    try {
      await Future.wait(
        targets.map(
          (target) => _delayTestPool.run(() => _runDelayTest(job, target)),
        ),
      );
    } finally {
      _delayTestJobs.remove(job);
      for (final target in targets) {
        if (_latestDelayTestGeneration[target.key] == generation) {
          _latestDelayTestGeneration.remove(target.key);
        }
      }
      _flushDelayResults();
      final abandoned = job.held.toList();
      job.held.clear();
      pending.apply(
        finished: abandoned.where(job.startedOnDispatch.contains),
        released: abandoned.where(
          (key) => !job.startedOnDispatch.contains(key),
        ),
      );
    }
  }

  Future<void> _runDelayTest(_DelayTestJob job, _DelayTestTarget target) async {
    if (job.cancelled ||
        _latestDelayTestGeneration[target.key] != job.generation) {
      return;
    }
    if (!job.startedOnDispatch.contains(target.key)) {
      _bufferedStarts.add(target.key);
      _scheduleDelayFlush();
    }
    try {
      final delay = await _core.testDelay(
        TestDelayParams(
          proxyName: target.proxyName,
          testUrl: target.testUrl,
          timeout: job.timeout.inMilliseconds,
        ),
      );
      // An older request must not replace a fresher measurement.
      if (!job.cancelled &&
          _latestDelayTestGeneration[target.key] == job.generation) {
        setDelay(delay);
      }
    } catch (error) {
      if (error is CoreMethodException && error.isCoreUnavailable) {
        job.cancelled = true;
      }
      commonPrint.log(
        'Delay test failed for ${target.proxyName}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      if (job.held.remove(target.key)) {
        _bufferedFinishes.add(target.key);
        _scheduleDelayFlush();
      }
    }
  }
}
