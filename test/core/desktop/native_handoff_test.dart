import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_handoff.dart';
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

    await expectLater(
      otherHandoff.activate(spec),
      throwsA(isA<StateError>()),
    );
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
          Future.error(ProcessException('sing-box', [], 'spawn failed')),
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

  test('unexpected external process exit automatically recovers Mihomo',
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
  });

  test('an originally stopped Mihomo is not started on native exit',
      () async {
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
