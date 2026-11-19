import 'dart:async';

import 'native_core.dart';
import 'native_proxy.dart';

typedef MihomoRunSetter = Future<bool> Function(bool running);

/// Coordinates the handoff of network listeners between Mihomo and a native
/// sing-box/Xray process. It does not guess native proxy ports or rewrite
/// native JSON configurations.
final class NativeCoreHandoff {
  final NativeCoreRuntime runtime;
  final bool restartHttpCoreOnCrash;
  final bool Function() isMihomoRunning;
  final MihomoRunSetter setMihomoRunning;
  final Future<void> Function() releaseMihomoProxy;
  final bool Function() useNativeSystemProxy;
  final Future<NativeHttpEndpoint?> Function(NativeCoreSpec) detectHttpEndpoint;
  final Future<NativeTunConfiguration?> Function(NativeCoreSpec) detectTun;
  final Future<bool> Function(NativeHttpEndpoint) isHttpPortAvailable;
  final Future<bool> Function(NativeHttpEndpoint) waitForHttpEndpoint;
  final Future<bool> Function(int) activateNativeProxy;
  final Future<void> Function() releaseNativeProxy;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<bool> _busyChanges =
      StreamController<bool>.broadcast();

  late final StreamSubscription<NativeCoreExit> _exitSubscription;
  bool _busy = false;
  bool _restoreMihomo = false;
  bool _unexpectedExit = false;
  bool _nativeProxyOwned = false;
  bool _nativeTunConfigured = false;
  NativeCoreSpec? _restartSpec;
  NativeHttpEndpoint? _restartEndpoint;
  bool _restartAttempted = false;

  NativeCoreHandoff({
    required this.runtime,
    this.restartHttpCoreOnCrash = false,
    required this.isMihomoRunning,
    required this.setMihomoRunning,
    required this.releaseMihomoProxy,
    this.useNativeSystemProxy = _noNativeProxy,
    this.detectHttpEndpoint = detectNativeHttpEndpoint,
    this.detectTun = detectNativeTunConfiguration,
    this.isHttpPortAvailable = isNativeHttpPortAvailable,
    this.waitForHttpEndpoint = waitForNativeHttpEndpoint,
    this.activateNativeProxy = _noNativeProxyActivation,
    this.releaseNativeProxy = _releaseNothing,
  }) {
    _exitSubscription = runtime.exits.listen((event) {
      if (event.expected) return;
      _unexpectedExit = true;
      if (!_busy) unawaited(_recoverAfterCrash());
    });
  }

  Stream<String> get messages => _messages.stream;

  Stream<bool> get busyChanges => _busyChanges.stream;

  bool get busy => _busy;

  void _setBusy(bool value) {
    _busy = value;
    if (!_busyChanges.isClosed) _busyChanges.add(value);
  }

  bool get hasMihomoToRestore => _restoreMihomo;

  bool get ownsNativeSystemProxy => _nativeProxyOwned;

  /// True while a running sing-box was launched with auto_route TUN.
  /// This is not an independent assertion of OS route or DNS health.
  bool get nativeTunConfigured => _nativeTunConfigured;

  bool get blocksMihomoStart => _busy || runtime.isRunning || _nativeProxyOwned;

  Future<void> activate(NativeCoreSpec spec) async {
    if (_busy || runtime.isRunning || _restoreMihomo || _nativeProxyOwned) {
      throw StateError('An external core is active or switching');
    }
    _setBusy(true);
    try {
      // Reject an invalid configuration before taking down a working route.
      final validation = await runtime.validate(spec);
      if (!validation.valid) {
        throw StateError('${spec.kind.label}: ${validation.details}');
      }
      final wantsSystemProxy = useNativeSystemProxy();
      final tun = await detectTun(spec);
      // A native auto-route TUN owns system routing itself. Do not also claim
      // the OS HTTP proxy even if the original Mihomo setting was enabled.
      final endpoint = wantsSystemProxy && tun == null
          ? await detectHttpEndpoint(spec)
          : null;
      if (wantsSystemProxy && endpoint == null && tun == null) {
        throw StateError(
          'Native config needs a loopback HTTP/mixed inbound or a sing-box '
          'auto_route TUN for system traffic',
        );
      }
      runtime.setNativeMode(true);
      if (isMihomoRunning()) {
        if (!await setMihomoRunning(false)) {
          throw StateError('Could not stop Mihomo network listeners');
        }
        _restoreMihomo = true;
      }
      try {
        await releaseMihomoProxy();
        if (endpoint != null && !await isHttpPortAvailable(endpoint)) {
          throw StateError(
            '${spec.kind.label} HTTP port ${endpoint.port} remains occupied '
            'after Mihomo stopped; refusing system proxy takeover',
          );
        }
        await runtime.start(spec);
        if (tun != null) {
          // A core that exits immediately cannot be trusted to have set up
          // its TUN. The core itself still owns route creation and cleanup.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!runtime.isRunning) {
            throw StateError('sing-box exited while starting native TUN');
          }
          _nativeTunConfigured = true;
          _emit(
            'sing-box TUN auto_route configured; actual system routing '
            'is managed by sing-box and is not independently verified',
          );
        } else if (endpoint != null) {
          if (!await waitForHttpEndpoint(endpoint) || !runtime.isRunning) {
            throw StateError(
              '${spec.kind.label} HTTP port ${endpoint.port} did not start',
            );
          }
          // Mark ownership before writing OS settings so any partial platform
          // failure is cleaned up during rollback.
          _nativeProxyOwned = true;
          if (!await activateNativeProxy(endpoint.port)) {
            throw StateError('Could not activate native system proxy');
          }
          _emit(
            '${spec.kind.label} system proxy active on 127.0.0.1:${endpoint.port}',
          );
        } else {
          _emit('${spec.kind.label} running without system proxy takeover');
        }
        // Only an HTTP endpoint whose readiness was verified is eligible for
        // automatic restart. Native TUN route health cannot be inferred here.
        _restartSpec = endpoint == null ? null : spec;
        _restartEndpoint = endpoint;
        _restartAttempted = false;
      } catch (error, stackTrace) {
        _clearRestartCandidate();
        // The external core failed: put the previous route back.
        if (runtime.isRunning) await runtime.stop();
        _nativeTunConfigured = false;
        await _releaseProxy();
        await _restore();
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      _setBusy(false);
      if (!runtime.isRunning && !_restoreMihomo && !_nativeProxyOwned) {
        runtime.setNativeMode(false);
      }
      if (_unexpectedExit) unawaited(_recoverAfterCrash());
    }
  }

  Future<void> deactivate() async {
    if (_busy) throw StateError('Core switching is already in progress');
    _setBusy(true);
    try {
      // Never re-enable Mihomo while the external process might still own TUN.
      await runtime.stop();
      _clearRestartCandidate();
      await _releaseProxy();
      _nativeTunConfigured = false;
      runtime.setNativeMode(false);
      await _restore();
      _unexpectedExit = false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _releaseProxy() async {
    if (!_nativeProxyOwned) return;
    await releaseNativeProxy();
    _nativeProxyOwned = false;
  }

  Future<void> _restore() async {
    if (!_restoreMihomo) return;
    runtime.setNativeMode(false);
    if (!await setMihomoRunning(true)) {
      throw StateError('Mihomo could not be restarted after native core exit');
    }
    _restoreMihomo = false;
    _emit('Mihomo network listeners restored');
  }

  Future<void> _recoverAfterCrash() async {
    if (_busy || !_unexpectedExit || runtime.isRunning) return;
    _setBusy(true);
    // Consume this exit so a second unexpected exit during restart can be
    // handled after the current recovery completes.
    _unexpectedExit = false;
    try {
      final spec = _restartSpec;
      final endpoint = _restartEndpoint;
      if (restartHttpCoreOnCrash &&
          !_restartAttempted &&
          spec != null &&
          endpoint != null) {
        _restartAttempted = true;
        _emit('${spec.kind.label} exited unexpectedly; retrying native core');
        try {
          // Restore a verifiable local HTTP listener before reclaiming the
          // system proxy. Never run both native and Mihomo network listeners.
          await _releaseProxy();
          if (!await isHttpPortAvailable(endpoint)) {
            throw StateError('Native HTTP port ${endpoint.port} is occupied');
          }
          await runtime.start(spec);
          if (!await waitForHttpEndpoint(endpoint) || !runtime.isRunning) {
            throw StateError('Native HTTP listener did not recover');
          }
          _nativeProxyOwned = true;
          if (!await activateNativeProxy(endpoint.port) || !runtime.isRunning) {
            throw StateError('Native system proxy recovery failed');
          }
          _emit('${spec.kind.label} automatically restarted');
          return;
        } catch (error) {
          _emit('${spec.kind.label} restart failed: $error; restoring Mihomo');
          if (runtime.isRunning) await runtime.stop();
        }
      }
      await _releaseProxy();
      _nativeTunConfigured = false;
      runtime.setNativeMode(false);
      await _restore();
      _clearRestartCandidate();
    } catch (error) {
      _emit('Native core exited; Mihomo recovery failed: $error');
    } finally {
      _setBusy(false);
      if (_unexpectedExit && !runtime.isRunning) {
        unawaited(_recoverAfterCrash());
      }
    }
  }

  void _clearRestartCandidate() {
    _restartSpec = null;
    _restartEndpoint = null;
    _restartAttempted = false;
  }

  void _emit(String message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  Future<void> close() async {
    await _exitSubscription.cancel();
    await _busyChanges.close();
    await _messages.close();
  }
}

bool _noNativeProxy() => false;

Future<bool> _noNativeProxyActivation(int _) async => false;

Future<void> _releaseNothing() async {}
