import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_handoff.dart';
import 'package:fl_clash/core/desktop/native_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late NativeCoreSpec spec;
  late _Child child;
  late NativeCoreRuntime runtime;
  late bool mihomoRunning;
  late List<String> calls;
  late NativeCoreHandoff handoff;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('native handoff ');
    final file = File(p.join(temp.path, 'config.json'));
    await file.writeAsString('{}');
    spec = NativeCoreSpec(
      kind: NativeCoreKind.singBox,
      executable: 'sing-box',
      configPath: file.path,
    );
    child = _Child();
    runtime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async => ProcessResult(1, 0, '', ''),
      start: (_, _, {workingDirectory}) async => child,
    );
    mihomoRunning = true;
    calls = [];
    handoff = NativeCoreHandoff(
      runtime: runtime,
      isMihomoRunning: () => mihomoRunning,
      setMihomoRunning: (running) async {
        calls.add('mihomo:$running');
        mihomoRunning = running;
        return true;
      },
      releaseMihomoProxy: () async => calls.add('release proxy'),
    );
  });

  tearDown(() async {
    if (runtime.isRunning) await runtime.stop();
    await handoff.close();
    await runtime.close();
    await temp.delete(recursive: true);
  });

  test('releases Mihomo before native start and restores on stop', () async {
    await handoff.activate(spec);
    expect(calls, ['mihomo:false', 'release proxy']);
    expect(mihomoRunning, isFalse);
    expect(runtime.isRunning, isTrue);
    expect(runtime.blocksMihomoStart, isTrue);
    expect(handoff.hasMihomoToRestore, isTrue);

    await handoff.deactivate();
    expect(calls, ['mihomo:false', 'release proxy', 'mihomo:true']);
    expect(mihomoRunning, isTrue);
    expect(runtime.isRunning, isFalse);
    expect(runtime.blocksMihomoStart, isFalse);
    expect(handoff.hasMihomoToRestore, isFalse);
  });

  test('a native config validation error leaves Mihomo untouched', () async {
    final invalidRuntime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async =>
          ProcessResult(1, 1, '', 'invalid JSON config'),
    );
    final otherHandoff = NativeCoreHandoff(
      runtime: invalidRuntime,
      isMihomoRunning: () => mihomoRunning,
      setMihomoRunning: (value) async {
        mihomoRunning = value;
        return true;
      },
      releaseMihomoProxy: () async => calls.add('release proxy'),
    );

    await expectLater(otherHandoff.activate(spec), throwsA(isA<StateError>()));
    expect(mihomoRunning, isTrue);
    expect(invalidRuntime.blocksMihomoStart, isFalse);
    expect(calls, isEmpty);
    await otherHandoff.close();
    await invalidRuntime.close();
  });

  test('process launch failure rolls back previous Mihomo listeners', () async {
    final failedRuntime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async => ProcessResult(1, 0, '', ''),
      start: (_, _, {workingDirectory}) =>
          Future.error(const ProcessException('sing-box', [], 'spawn failed')),
    );
    final otherHandoff = NativeCoreHandoff(
      runtime: failedRuntime,
      isMihomoRunning: () => mihomoRunning,
      setMihomoRunning: (value) async {
        calls.add('mihomo:$value');
        mihomoRunning = value;
        return true;
      },
      releaseMihomoProxy: () async => calls.add('release proxy'),
    );

    await expectLater(
      otherHandoff.activate(spec),
      throwsA(isA<ProcessException>()),
    );
    expect(calls, ['mihomo:false', 'release proxy', 'mihomo:true']);
    expect(mihomoRunning, isTrue);
    expect(failedRuntime.blocksMihomoStart, isFalse);
    await otherHandoff.close();
    await failedRuntime.close();
  });

  test(
    'unexpected external process exit automatically recovers Mihomo',
    () async {
      final recovered = handoff.messages.firstWhere(
        (line) => line.contains('restored'),
      );
      await handoff.activate(spec);
      child.finish(2);
      expect(await recovered, contains('Mihomo'));
      expect(mihomoRunning, isTrue);
      expect(runtime.blocksMihomoStart, isFalse);
      expect(handoff.hasMihomoToRestore, isFalse);
    },
  );

  test(
    'HTTP system proxy is applied after native readiness and removed first',
    () async {
      final proxyHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (value) async {
          calls.add('mihomo:$value');
          mihomoRunning = value;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release mihomo proxy'),
        useNativeSystemProxy: () => true,
        detectHttpEndpoint: (_) async => const NativeHttpEndpoint(8090),
        isHttpPortAvailable: (_) async => true,
        waitForHttpEndpoint: (endpoint) async {
          calls.add('ready:${endpoint.port}');
          return true;
        },
        activateNativeProxy: (port) async {
          calls.add('native proxy:$port');
          return true;
        },
        releaseNativeProxy: () async => calls.add('release native proxy'),
      );

      await proxyHandoff.activate(spec);
      expect(calls, [
        'mihomo:false',
        'release mihomo proxy',
        'ready:8090',
        'native proxy:8090',
      ]);
      await proxyHandoff.deactivate();
      expect(calls.sublist(4), ['release native proxy', 'mihomo:true']);
      await proxyHandoff.close();
    },
  );

  test(
    'occupied HTTP port restores Mihomo without launching native core',
    () async {
      final proxyHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (value) async {
          calls.add('mihomo:$value');
          mihomoRunning = value;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release mihomo proxy'),
        useNativeSystemProxy: () => true,
        detectHttpEndpoint: (_) async => const NativeHttpEndpoint(8090),
        isHttpPortAvailable: (endpoint) async {
          calls.add('occupied:${endpoint.port}');
          return false;
        },
        waitForHttpEndpoint: (_) async =>
            throw StateError('native readiness must not be probed'),
        activateNativeProxy: (_) async =>
            throw StateError('system proxy must not change'),
      );

      await expectLater(
        proxyHandoff.activate(spec),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('remains occupied'),
          ),
        ),
      );
      expect(calls, [
        'mihomo:false',
        'release mihomo proxy',
        'occupied:8090',
        'mihomo:true',
      ]);
      expect(runtime.isRunning, isFalse);
      expect(mihomoRunning, isTrue);
      expect(runtime.blocksMihomoStart, isFalse);
      await proxyHandoff.close();
    },
  );

  test(
    'missing compatible HTTP inbound preserves the existing connection',
    () async {
      final proxyHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (value) async {
          calls.add('mihomo:$value');
          mihomoRunning = value;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release mihomo proxy'),
        useNativeSystemProxy: () => true,
        detectHttpEndpoint: (_) async => null,
      );

      await expectLater(proxyHandoff.activate(spec), throwsStateError);
      expect(calls, isEmpty);
      expect(mihomoRunning, isTrue);
      expect(runtime.isRunning, isFalse);
      await proxyHandoff.close();
    },
  );

  test(
    'HTTP system proxy activation failure releases it and restores Mihomo',
    () async {
      final proxyHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (value) async {
          calls.add('mihomo:$value');
          mihomoRunning = value;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release mihomo proxy'),
        useNativeSystemProxy: () => true,
        detectHttpEndpoint: (_) async => const NativeHttpEndpoint(8090),
        isHttpPortAvailable: (_) async => true,
        waitForHttpEndpoint: (_) async => true,
        activateNativeProxy: (_) async {
          calls.add('native start failed');
          return false;
        },
        releaseNativeProxy: () async => calls.add('release native proxy'),
      );

      await expectLater(proxyHandoff.activate(spec), throwsStateError);
      expect(calls, [
        'mihomo:false',
        'release mihomo proxy',
        'native start failed',
        'release native proxy',
        'mihomo:true',
      ]);
      expect(runtime.isRunning, isFalse);
      expect(mihomoRunning, isTrue);
      await proxyHandoff.close();
    },
  );

  test(
    'native process crash releases system proxy before Mihomo restarts',
    () async {
      final proxyHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (value) async {
          calls.add('mihomo:$value');
          mihomoRunning = value;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release mihomo proxy'),
        useNativeSystemProxy: () => true,
        detectHttpEndpoint: (_) async => const NativeHttpEndpoint(8090),
        isHttpPortAvailable: (_) async => true,
        waitForHttpEndpoint: (_) async => true,
        activateNativeProxy: (_) async => true,
        releaseNativeProxy: () async => calls.add('release native proxy'),
      );

      final recovered = proxyHandoff.messages.firstWhere(
        (message) => message.contains('restored'),
      );
      await proxyHandoff.activate(spec);
      child.finish(3);
      await recovered;
      expect(calls.sublist(calls.length - 2), [
        'release native proxy',
        'mihomo:true',
      ]);
      await proxyHandoff.close();
    },
  );

  test(
    'sing-box TUN auto_route takes precedence over HTTP system proxy',
    () async {
      final tunHandoff = NativeCoreHandoff(
        runtime: runtime,
        isMihomoRunning: () => mihomoRunning,
        setMihomoRunning: (running) async {
          calls.add('mihomo:$running');
          mihomoRunning = running;
          return true;
        },
        releaseMihomoProxy: () async => calls.add('release proxy'),
        useNativeSystemProxy: () => true,
        detectTun: (_) async => const NativeTunConfiguration(
          interfaceName: 'sing-tun',
          dnsMode: 'hijack',
        ),
        detectHttpEndpoint: (_) async => throw StateError(
          'HTTP endpoint must not be inspected for native TUN',
        ),
        activateNativeProxy: (_) async =>
            throw StateError('system HTTP proxy must not be activated'),
      );

      await tunHandoff.activate(spec);
      expect(tunHandoff.nativeTunConfigured, isTrue);
      expect(tunHandoff.ownsNativeSystemProxy, isFalse);
      expect(mihomoRunning, isFalse);
      expect(calls, ['mihomo:false', 'release proxy']);
      await tunHandoff.deactivate();
      expect(tunHandoff.nativeTunConfigured, isFalse);
      expect(mihomoRunning, isTrue);
      expect(calls.last, 'mihomo:true');
      await tunHandoff.close();
    },
  );

  test('native TUN crash restores previously running Mihomo', () async {
    final tunHandoff = NativeCoreHandoff(
      runtime: runtime,
      isMihomoRunning: () => mihomoRunning,
      setMihomoRunning: (running) async {
        calls.add('mihomo:$running');
        mihomoRunning = running;
        return true;
      },
      releaseMihomoProxy: () async => calls.add('release proxy'),
      useNativeSystemProxy: () => true,
      detectTun: (_) async => const NativeTunConfiguration(),
    );
    final recovered = tunHandoff.messages.firstWhere(
      (message) => message.contains('restored'),
    );
    await tunHandoff.activate(spec);
    child.finish(1);
    await recovered;
    expect(tunHandoff.nativeTunConfigured, isFalse);
    expect(mihomoRunning, isTrue);
    expect(runtime.blocksMihomoStart, isFalse);
    await tunHandoff.close();
  });

  test('an originally stopped Mihomo is not started on native exit', () async {
    mihomoRunning = false;
    await handoff.activate(spec);
    expect(calls, ['release proxy']);
    await handoff.deactivate();
    expect(calls, ['release proxy']);
    expect(mihomoRunning, isFalse);
    expect(runtime.blocksMihomoStart, isFalse);
  });
}

class _Child implements Process {
  final Completer<int> _exit = Completer<int>();

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  int get pid => 321;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
