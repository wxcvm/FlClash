import 'dart:async';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';

class _FakeProxy implements Proxy {
  final List<String> calls = [];
  Future<bool>? held;
  Error? failure;

  Future<bool> _call(String name) async {
    calls.add(name);
    final error = failure;
    failure = null;
    if (error != null) {
      throw error;
    }
    final result = held ?? Future.value(true);
    held = null;
    return result;
  }

  @override
  Future<bool> startProxy(int port, [List<String> bypassDomain = const []]) {
    return _call('start $port');
  }

  @override
  Future<bool> stopProxy() => _call('stop');
}

ProxyState _state({required bool isStart}) {
  return ProxyState(
    isStart: isStart,
    systemProxy: true,
    bassDomain: const [],
    port: 7890,
  );
}

void main() {
  test('PowerShell proxy command sets HTTP, HTTPS and ALL proxy variables', () {
    expect(
      proxyEnvCommand(7890, isWindows: true),
      "\$env:HTTP_PROXY = 'http://127.0.0.1:7890'; "
      "\$env:HTTPS_PROXY = 'http://127.0.0.1:7890'; "
      "\$env:ALL_PROXY = 'http://127.0.0.1:7890'",
    );
  });

  test('POSIX proxy command replaces both uppercase and lowercase values', () {
    expect(
      proxyEnvCommand(7890, isWindows: false),
      "export http_proxy='http://127.0.0.1:7890' "
      "https_proxy='http://127.0.0.1:7890' "
      "all_proxy='http://127.0.0.1:7890' "
      "HTTP_PROXY='http://127.0.0.1:7890' "
      "HTTPS_PROXY='http://127.0.0.1:7890' "
      "ALL_PROXY='http://127.0.0.1:7890'",
    );
  });

  test('applies changes in the order they come', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    unawaited(queue.apply(_state(isStart: true)));
    await queue.apply(_state(isStart: false));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('close stops last and drops the starts queued before it', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    final inFlight = Completer<bool>();
    proxy.held = inFlight.future;

    unawaited(queue.apply(_state(isStart: true)));
    await pumpEventQueue();
    unawaited(queue.apply(_state(isStart: true)));
    final closed = queue.close();
    await pumpEventQueue();
    expect(proxy.calls, ['start 7890']);

    inFlight.complete(true);
    await closed;
    await queue.apply(_state(isStart: true));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('a failing call does not stall the queue', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    proxy.failure = StateError('channel gone');

    await queue.apply(_state(isStart: true));
    await queue.apply(_state(isStart: false));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('leaves a proxy it never set alone', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    await queue.apply(_state(isStart: false));
    await queue.close();

    expect(proxy.calls, isEmpty);
  });

  test(
    'native owner keeps Mihomo watcher updates from overriding its port',
    () async {
      final proxy = _FakeProxy();
      final queue = SystemProxyQueue(proxy);

      await queue.apply(_state(isStart: true));
      expect(await queue.activateNative(8090, const []), isTrue);
      await queue.apply(_state(isStart: false));
      await queue.apply(_state(isStart: true));
      await queue.releaseNative();
      await queue.apply(_state(isStart: true));

      expect(proxy.calls, ['start 7890', 'start 8090', 'stop', 'start 7890']);
    },
  );

  test(
    'failed native proxy activation returns false and restores ownership',
    () async {
      final proxy = _FakeProxy();
      final queue = SystemProxyQueue(proxy);
      proxy.held = Future.value(false);

      expect(await queue.activateNative(8090, const []), isFalse);
      await queue.apply(_state(isStart: true));
      expect(proxy.calls, ['start 8090', 'stop', 'start 7890']);
    },
  );

  test('native activation exception releases ownership and cleans up', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    proxy.failure = StateError('channel gone');

    expect(await queue.activateNative(8090, const []), isFalse);
    await queue.apply(_state(isStart: true));
    await queue.apply(_state(isStart: false));

    expect(proxy.calls, ['start 8090', 'stop', 'start 7890', 'stop']);
  });

  test('closing the queue stops the native proxy owner', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    expect(await queue.activateNative(8090, const []), isTrue);
    await queue.close();
    expect(proxy.calls, ['start 8090', 'stop']);
  });

  test('tries a failed stop again on close', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    await queue.apply(_state(isStart: true));
    proxy.held = Future.value(false);
    await queue.apply(_state(isStart: false));
    await queue.close();
    await queue.close();

    expect(proxy.calls, ['start 7890', 'stop', 'stop']);
  });
}
