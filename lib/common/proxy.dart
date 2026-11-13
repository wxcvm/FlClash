import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

final systemProxyQueue = proxy == null ? null : SystemProxyQueue(proxy!);

/// Exit's stop goes through the same queue as every other change, so a start
/// still waiting behind a slow call cannot turn the proxy back on after it.
/// A stop also clears settings someone else made, so it only undoes a start
/// of this run.
class SystemProxyQueue {
  final Proxy _proxy;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _applied = false;
  bool _nativeOwner = false;
  int? _nativeHttpPort;

  /// Only expose a verified native HTTP proxy endpoint.
  int? get nativeHttpPort => _closed ? null : _nativeHttpPort;

  SystemProxyQueue(this._proxy);

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed || _nativeOwner) {
        return;
      }
      if (state.isStart && state.systemProxy) {
        _applied = true;
        var success = false;
        try {
          success = await _proxy.startProxy(state.port, state.bassDomain);
        } finally {
          if (!success) {
            _logFailure();
            await _stop();
          }
        }
      } else {
        await _stop();
      }
    });
  }

  /// Explicit handoff must know whether the previous proxy was released.
  Future<void> releaseMihomo() => _enqueue(() async {
    if (_nativeOwner || !await _stop()) {
      throw StateError('Could not release Mihomo system proxy');
    }
  }, propagate: true);

  /// Native cores own the system proxy until releaseNative() is called.
  /// Mihomo state-watch updates are queued but cannot overwrite that owner.
  Future<bool> activateNative(int port, List<String> bypassDomain) async {
    var success = false;
    await _enqueue(() async {
      if (_closed) return;
      _nativeOwner = true;
      _nativeHttpPort = null;
      _applied = true;
      try {
        success = await _proxy.startProxy(port, bypassDomain);
        if (success) _nativeHttpPort = port;
      } finally {
        if (!success) {
          _logFailure();
          if (await _stop()) _nativeOwner = false;
        }
      }
    });
    return success;
  }

  Future<void> releaseNative() => _enqueue(() async {
    if (!_nativeOwner) return;
    _nativeHttpPort = null;
    if (!await _stop()) {
      throw StateError('Could not release native system proxy');
    }
    _nativeOwner = false;
  }, propagate: true);

  Future<void> close() {
    _closed = true;
    _nativeHttpPort = null;
    return _enqueue(() async {
      _nativeOwner = false;
      await _stop();
    });
  }

  Future<bool> _stop() async {
    if (!_applied) {
      return true;
    }
    if (!await _proxy.stopProxy()) {
      _logFailure();
      return false;
    }
    _applied = false;
    return true;
  }

  void _logFailure() {
    commonPrint.log('update system proxy failed', logLevel: LogLevel.warning);
  }

  Future<void> _enqueue(
    Future<void> Function() task, {
    bool propagate = false,
  }) {
    final operation = _tail.then((_) => task());
    _tail = operation.catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
    return propagate ? operation : _tail;
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  if (isWindows) {
    return [
      "\$env:HTTP_PROXY = '$url'",
      "\$env:HTTPS_PROXY = '$url'",
      "\$env:ALL_PROXY = '$url'",
    ].join('; ');
  }
  return "export http_proxy='$url' https_proxy='$url' all_proxy='$url' "
      "HTTP_PROXY='$url' HTTPS_PROXY='$url' ALL_PROXY='$url'";
}
