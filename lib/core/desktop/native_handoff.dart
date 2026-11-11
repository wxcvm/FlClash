import 'dart:async';

import 'native_core.dart';

typedef MihomoRunSetter = Future<bool> Function(bool running);

/// Coordinates the handoff of network listeners between Mihomo and a native
/// sing-box/Xray process. It does not guess native proxy ports or rewrite
/// native JSON configurations.
final class NativeCoreHandoff {
  final NativeCoreRuntime runtime;
  final bool Function() isMihomoRunning;
  final MihomoRunSetter setMihomoRunning;
  final Future<void> Function() releaseMihomoProxy;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  late final StreamSubscription<NativeCoreExit> _exitSubscription;
  bool _busy = false;
  bool _restoreMihomo = false;
  bool _unexpectedExit = false;

  NativeCoreHandoff({
    required this.runtime,
    required this.isMihomoRunning,
    required this.setMihomoRunning,
    required this.releaseMihomoProxy,
  }) {
    _exitSubscription = runtime.exits.listen((event) {
      if (event.expected || !_restoreMihomo) return;
      _unexpectedExit = true;
      if (!_busy) unawaited(_recoverAfterCrash());
    });
  }

  Stream<String> get messages => _messages.stream;

  bool get busy => _busy;

  bool get hasMihomoToRestore => _restoreMihomo;

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
      if (isMihomoRunning()) {
        if (!await setMihomoRunning(false)) {
          throw StateError('Could not stop Mihomo network listeners');
        }
        _restoreMihomo = true;
      }
      try {
        await releaseMihomoProxy();
        await runtime.start(spec);
        _emit('${spec.kind.label} started; Mihomo network listeners released');
      } catch (error, stackTrace) {
        // The external core failed: put the previous route back.
        await _restore();
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      _busy = false;
      if (_unexpectedExit) unawaited(_recoverAfterCrash());
    }
  }

  Future<void> deactivate() async {
    if (_busy) throw StateError('Core switching is already in progress');
    _busy = true;
    try {
      // Never re-enable Mihomo while the external process might still own TUN.
      await runtime.stop();
      await _restore();
      _unexpectedExit = false;
    } finally {
      _busy = false;
    }
  }

  Future<void> _restore() async {
    if (!_restoreMihomo) return;
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
