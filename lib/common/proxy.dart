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

  SystemProxyQueue(this._proxy);

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed || _nativeOwner) {
        return;
      }
      if (state.isStart && state.systemProxy) {
        _applied = true;
        if (!await _proxy.startProxy(state.port, state.bassDomain)) {
          _logFailure();
        }
      } else {
        await _stop();
      }
    });
  }

  /// Native cores own the system proxy until releaseNative() is called.
  /// Mihomo state-watch updates are queued but cannot overwrite that owner.
  Future<bool> activateNative(int port, List<String> bypassDomain) async {
    var success = false;
    await _enqueue(() async {
      if (_closed) return;
      _nativeOwner = true;
      _applied = true;
      success = await _proxy.startProxy(port, bypassDomain);
      if (!success) {
        _nativeOwner = false;
        _logFailure();
        await _stop();
      }
    });
    return success;
  }

  Future<void> releaseNative() => _enqueue(() async {
    if (!_nativeOwner) return;
    _nativeOwner = false;
    await _stop();
  });

  Future<void> close() {
    _closed = true;
    return _enqueue(() async {
      _nativeOwner = false;
      await _stop();
    });
  }

  Future<void> _stop() async {
    if (!_applied) {
      return;
    }
    if (!await _proxy.stopProxy()) {
      _logFailure();
      return;
    }
    _applied = false;
  }

  void _logFailure() {
    commonPrint.log('update system proxy failed', logLevel: LogLevel.warning);
  }

  Future<void> _enqueue(Future<void> Function() task) {
    return _tail = _tail.then((_) => task()).catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  return isWindows ? 'set \$env:all_proxy=$url' : 'export all_proxy=$url';
}
