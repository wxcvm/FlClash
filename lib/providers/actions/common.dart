part of '../action.dart';

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  CoreController get _core => ref.read(coreHandlerProvider);
  bool _isUpdatingTraffic = false;
  CancelToken? _updateCancelToken;
  bool _installingUpdate = false;
  bool _awaitingExternalInstaller = false;

  @override
  void build() {
    final observer = _UpdateInstallerLifecycleObserver(() {
      if (!_awaitingExternalInstaller) {
        return;
      }
      _awaitingExternalInstaller = false;
      commonPrint.log('Update installer: returned to FlClash');
    });
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  }

  void toggleRunning() {
    final running = !ref.read(isStartProvider);
    unawaited(
      globalState.safeRun(
        () => ref
            .read(setupActionProvider.notifier)
            .setRunning(
              running,
              initialize: running && !ref.read(initProvider),
            ),
      ),
    );
  }

  void updateSpeedStatistics() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMonochromeTrayIcon() {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(monochromeTrayIcon: !state.monochromeTrayIcon),
        );
  }

  void updateMode() {
    ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) return state;
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  Future<void> updateTraffic() async {
    if (_isUpdatingTraffic || service?.nativeOwnsRuntime == true) {
      return;
    }
    _isUpdatingTraffic = true;
    try {
      final onlyStatisticsProxy = ref.read(
        appSettingProvider.select((state) => state.onlyStatisticsProxy),
      );
      final [traffic, totalTraffic] = await Future.wait([
        _readTraffic(() => _core.getTraffic(onlyStatisticsProxy)),
        _readTraffic(() => _core.getTotalTraffic(onlyStatisticsProxy)),
      ]);
      if (service?.nativeOwnsRuntime == true) return;
      if (traffic != null) {
        ref.read(trafficsProvider.notifier).addTraffic(traffic);
      }
      if (totalTraffic != null) {
        ref.read(totalTrafficProvider.notifier).value = totalTraffic;
      }
    } finally {
      _isUpdatingTraffic = false;
    }
  }

  Future<Traffic?> _readTraffic(Future<Traffic> Function() request) async {
    try {
      return await request();
    } catch (error) {
      commonPrint.log(
        'updateTraffic error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  Future<bool> autoCheckUpdate() async {
    if (!ref.read(appSettingProvider).autoCheckUpdate) return false;
    final Map<String, dynamic>? res;
    try {
      res = await request.checkForUpdate();
    } catch (error) {
      commonPrint.log(
        'checkForUpdate failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return false;
    }
    await checkUpdateResultHandle(data: res);
    return res != null;
  }

  TextSpan _releaseSpan(BuildContext context, String tagName, String? body) {
    final version = parseReleaseChangelog(body);
    return TextSpan(
      text: '$tagName \n',
      style: AppTextStyle.title2.of(context),
      children: version == null
          ? [
              TextSpan(text: '\n', style: AppTextStyle.subheadline.of(context)),
              for (final submit in parseReleaseBody(body))
                TextSpan(
                  text: '- $submit \n',
                  style: AppTextStyle.subheadline.of(context),
                ),
            ]
          : _changelogSpans(context, version),
    );
  }

  List<TextSpan> _changelogSpans(
    BuildContext context,
    ChangelogVersion version,
  ) {
    return [
      for (final group in version.visibleGroups) ...[
        TextSpan(
          text:
              '\n${changelogGroupTitle(currentAppLocalizations, group.type)}\n',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(
                color: group.type == ChangelogType.breaking
                    ? context.colorScheme.error
                    : context.colorScheme.primary,
              ),
        ),
        for (final entry in group.entries)
          TextSpan(
            text: '• ${entry.text}\n',
            style: AppTextStyle.subheadline.of(context),
          ),
      ],
    ];
  }

  Future<void> checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool isUser = false,
  }) async {
    if (data != null) {
      final context = globalState.navigatorKey.currentContext!;
      final tag = data['tag_name'] as String;
      final suffix = selfUpdateSuffix;
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.discoverNewVersion,
        message: _releaseSpan(context, tag, data['body'] as String?),
        confirmText: suffix == null
            ? currentAppLocalizations.goDownload
            : currentAppLocalizations.update,
        cancelText: isUser ? null : currentAppLocalizations.noLongerRemind,
      );
      if (res == true) {
        if (suffix == null) {
          _openReleasePage();
        } else {
          unawaited(_downloadUpdate(tag, releaseAssetName(tag, suffix)));
        }
      } else if (!isUser && res == false) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoCheckUpdate: false));
      }
    } else if (isUser) {
      unawaited(
        dialogs.showAlert(
          title: currentAppLocalizations.checkUpdate,
          message: TextSpan(text: currentAppLocalizations.checkUpdateError),
        ),
      );
    }
  }

  void _openReleasePage() {
    unawaited(launchUrl(Uri.parse('https://github.com/$repository/releases')));
  }

  /// Downloads the latest release for this build even when it is not newer.
  Future<void> testUpdateDownload() async {
    final suffix = selfUpdateSuffix;
    if (suffix == null || ref.read(updateDownloadStateProvider) != null) {
      return;
    }
    final release = await globalState.loadingRun(
      request.latestRelease,
      title: currentAppLocalizations.updateDownloadTest,
      tag: LoadingTag.checkUpdate,
    );
    if (release == null) return;
    final tag = release['tag_name'] as String;
    await _downloadUpdate(tag, releaseAssetName(tag, suffix));
  }

  Future<void> _downloadUpdate(String tag, String name) async {
    final download = ref.read(updateDownloadStateProvider.notifier);
    if (download.value != null) return;
    final cancelToken = CancelToken();
    _updateCancelToken = cancelToken;
    download.value = UpdateDownloading(tag);
    dialogs.showBanner(currentAppLocalizations.updateDownloadStarted);
    try {
      final directory = await appPath.updateDirPath;
      await clearUpdateDownloads();
      await Directory(directory).create(recursive: true);
      var shown = 0;
      final path = await request.downloadVerifiedRelease(
        tag: tag,
        name: name,
        directory: directory,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          // Every chunk would otherwise rebuild the status on its own frame.
          final step = total > 0 ? total / 100 : 1 << 20;
          if (received - shown < step && received != total) return;
          shown = received;
          download.value = UpdateDownloading(
            tag,
            received: received,
            total: total,
          );
        },
      );
      download.value = UpdateReady(tag, path);
      dialogs.showBanner(
        currentAppLocalizations.updateReadyTip,
        level: BannerLevel.success,
        onTap: () => unawaited(installUpdate()),
      );
    } catch (error) {
      // Keep the download slot occupied until cleanup finishes. Otherwise a
      // retry can create a new file while the previous attempt deletes it.
      try {
        await clearUpdateDownloads();
      } finally {
        download.value = null;
      }
      if (error is DioException && CancelToken.isCancel(error)) {
        return;
      }
      commonPrint.log(
        'Update download failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      await _showUpdateFailure(
        userFacingErrorMessage(error, currentAppLocalizations),
      );
    } finally {
      if (identical(_updateCancelToken, cancelToken)) {
        _updateCancelToken = null;
      }
    }
  }

  void cancelUpdateDownload() {
    _updateCancelToken?.cancel();
  }

  Future<void> discardUpdate() async {
    if (_installingUpdate ||
        _awaitingExternalInstaller ||
        ref.read(updateDownloadStateProvider) is! UpdateReady) {
      return;
    }
    ref.read(updateDownloadStateProvider.notifier).value = null;
    await clearUpdateDownloads();
  }

  Future<void> installUpdate() async {
    final download = ref.read(updateDownloadStateProvider);
    if (download is! UpdateReady) return;
    if (system.isAndroid) {
      final installer = app;
      if (installer == null ||
          _installingUpdate ||
          _awaitingExternalInstaller) {
        return;
      }
      _installingUpdate = true;
      try {
        commonPrint.log('Update installer: opening ${download.tag}');
        // Keep the verified APK protected until Android's installer activity
        // returns control to FlClash.
        _awaitingExternalInstaller = true;
        if (await installer.openPackageInstaller(download.path)) {
          commonPrint.log('Update installer: handed off to Android activity');
          // The external activity owns the install flow and may read the
          // content URI later. Keep the verified APK and the retry entry.
          return;
        }
        _awaitingExternalInstaller = false;
        commonPrint.log('Update installer: using Android package session');
        final status = await installer.installPackage(download.path);
        commonPrint.log('Update installer: session status $status');
        // Cancellation or failure must leave the verified APK available.
        if (status == 0) {
          await clearUpdateDownloads();
          if (ref.mounted) {
            ref.read(updateDownloadStateProvider.notifier).value = null;
          }
        }
      } on PlatformException catch (error) {
        _awaitingExternalInstaller = false;
        final detail = compactError(error);
        commonPrint.log(
          'Update installer failed: $detail',
          logLevel: LogLevel.warning,
        );
        if (ref.mounted) {
          await _showUpdateFailure(
            '${currentAppLocalizations.updateInstallFailed}\n\n$detail',
          );
        }
      } catch (_) {
        _awaitingExternalInstaller = false;
        rethrow;
      } finally {
        _installingUpdate = false;
      }
      return;
    }
    final started = windows?.runas(download.path, windowsUpdateArguments(pid));
    if (started == true) {
      await ref.read(systemActionProvider.notifier).handleExit();
    } else if (started == false) {
      await _showUpdateFailure(currentAppLocalizations.updateInstallFailed);
    }
  }

  Future<void> _showUpdateFailure(String message) async {
    final res = await dialogs.showMessage(
      title: currentAppLocalizations.updateFailed,
      message: TextSpan(text: message),
      confirmText: currentAppLocalizations.goDownload,
    );
    if (res == true) {
      _openReleasePage();
    }
  }
}

class _UpdateInstallerLifecycleObserver extends WidgetsBindingObserver {
  _UpdateInstallerLifecycleObserver(this.onResumed);

  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}
