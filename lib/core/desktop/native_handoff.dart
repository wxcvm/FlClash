import 'dart:async';

import 'native_core.dart';
import 'native_proxy.dart';

typedef MihomoRunSetter = Future<bool> Function(bool running);

/// Coordinates the handoff of network listeners between Mihomo and a native
/// sing-box/Xray process. It does not guess native proxy ports or rewrite
/// native JSON configurations.
final class NativeCoreHandoff {
  final NativeCoreRuntime runtime;
  final bool Function() isMihomoRunning;
  final MihomoRunSetter setMihomoRunning;
  final Future<void> Function() releaseMihomoProxy;
  final bool Function() useNativeSystemProxy;
  final Future<NativeHttpEndpoint?> Function(NativeCoreSpec) detectHttpEndpoint;
  final Future<NativeTunConfiguration?> Function(NativeCoreSpec) detectTun;
  final Future<bool> Function(NativeHttpEndpoint) waitForHttpEndpoint;
  final Future<bool> Function(int) activateNativeProxy;
  final Future<void> Function() releaseNativeProxy;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  late final StreamSubscription<NativeCoreExit> _exitSubscription;
  bool _busy = false;
  bool _restoreMihomo = false;
  bool _unexpectedExit = false;
  bool _nativeProxyOwned = false;
  bool _nativeTunConfigured = false;

  NativeCoreHandoff({
    required this.runtime,
    required this.isMihomoRunning,
    required this.setMihomoRunning,
    required this.releaseMihomoProxy,
    this.useNativeSystemProxy = _noNativeProxy,
    this.detectHttpEndpoint = detectNativeHttpEndpoint,
    this.detectTun = detectNativeTunConfiguration,
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

  bool get busy => _busy;

  bool get hasMihomoToRestore => _restoreMihomo;

  bool get ownsNativeSystemProxy => _nativeProxyOwned;

  /// True while a running sing-box was launched with auto_route TUN.
  /// This is not an independent assertion of OS route or DNS health.
  bool get nativeTunConfigured => _nativeTunConfigured;

  bool get blocksMihomoStart => _busy || runtime.isRunning;

  Future<void> activate(NativeCoreSpec spec) async {
    if (_busy || runtime.isRunning || _restoreMihomo) {
      throw StateError('An external core is active or switching');
    }
    _busy = true;
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
      } catch (error, stackTrace) {
        // The external core failed: put the previous route back.
        await _releaseProxy();
        if (runtime.isRunning) await runtime.stop();
        _nativeTunConfigured = false;
        await _restore();
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      _busy = false;
      if (!runtime.isRunning && !_restoreMihomo) {
        runtime.setNativeMode(false);
      }
      if (_unexpectedExit) unawaited(_recoverAfterCrash());
    }
  }

  Future<void> deactivate() async {
    if (_busy) throw StateError('Core switching is already in progress');
    _busy = true;
    try {
      // Never re-enable Mihomo while the external process might still own TUN.
      await runtime.stop();
      await _releaseProxy();
      _nativeTunConfigured = false;
      runtime.setNativeMode(false);
      await _restore();
      _unexpectedExit = false;
    } finally {
      _busy = false;
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
    _busy = true;
    try {
      await _releaseProxy();
      _nativeTunConfigured = false;
      runtime.setNativeMode(false);
      await _restore();
      _unexpectedExit = false;
    } catch (error) {
      _emit('Native core exited; Mihomo recovery failed: $error');
    } finally {
      _busy = false;
    }
  }

  void _emit(String message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  Future<void> close() async {
    await _exitSubscription.cancel();
    await _messages.close();
  }
}

bool _noNativeProxy() => false;

Future<bool> _noNativeProxyActivation(int _) async => false;

Future<void> _releaseNothing() async {}
