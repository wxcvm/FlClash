import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('native cores keep their distinct check and run CLI flags', () {
    expect(NativeCoreKind.singBox.checkArguments('config.json'), [
      'check',
      '-c',
      'config.json',
    ]);
    expect(NativeCoreKind.singBox.runArguments('config.json'), [
      'run',
      '-c',
      'config.json',
    ]);
    expect(NativeCoreKind.xray.checkArguments('config.json'), [
      'run',
      '-test',
      '-config',
      'config.json',
    ]);
    expect(NativeCoreKind.xray.runArguments('config.json'), [
      'run',
      '-config',
      'config.json',
    ]);
  });

  late Directory tempDir;
  late NativeCoreSpec spec;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('native core ');
    final config = File(p.join(tempDir.path, 'config.json'));
    await config.writeAsString('{}');
    spec = NativeCoreSpec(
      kind: NativeCoreKind.singBox,
      executable: 'sing-box',
      configPath: config.path,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('validates config using the native CLI in its directory', () async {
    String? program;
    List<String>? args;
    String? cwd;
    final runtime = NativeCoreRuntime(
      run: (executable, arguments, {workingDirectory}) async {
        program = executable;
        args = arguments;
        cwd = workingDirectory;
        return ProcessResult(17, 0, 'ok', '');
      },
    );

    final result = await runtime.validate(spec);

    expect(result.valid, isTrue);
    expect(result.details, 'ok');
    expect(program, 'sing-box');
    expect(args, ['check', '-c', spec.absoluteConfigPath]);
    expect(cwd, tempDir.path);
    await runtime.close();
  });

  test('starts one native process and stops the owned process', () async {
    final process = _FakeProcess();
    String? command;
    List<String>? arguments;
    String? cwd;
    final runtime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async => ProcessResult(1, 0, '', ''),
      start: (executable, args, {workingDirectory}) async {
        command = executable;
        arguments = args;
        cwd = workingDirectory;
        return process;
      },
    );

    await runtime.start(spec);
    expect(runtime.isRunning, isTrue);
    expect(runtime.activeKind, NativeCoreKind.singBox);
    expect(command, 'sing-box');
    expect(arguments, ['run', '-c', spec.absoluteConfigPath]);
    expect(cwd, tempDir.path);
    await expectLater(runtime.start(spec), throwsStateError);

    await runtime.stop();
    expect(process.killed, isTrue);
    expect(runtime.isRunning, isFalse);
    expect(runtime.activeKind, isNull);
    await runtime.close();
  });

  test('a failed native config check never launches the process', () async {
    var launches = 0;
    final runtime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async =>
          ProcessResult(1, 1, '', 'invalid outbound'),
      start: (_, _, {workingDirectory}) async {
        launches++;
        return _FakeProcess();
      },
    );

    await expectLater(
      runtime.start(spec),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('invalid outbound'),
        ),
      ),
    );
    expect(launches, 0);
    expect(runtime.isRunning, isFalse);
    await runtime.close();
  });

  test('a naturally exited native core clears its running state', () async {
    final process = _FakeProcess();
    final runtime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) async => ProcessResult(1, 0, '', ''),
      start: (_, _, {workingDirectory}) async => process,
    );
    final log = runtime.logs.firstWhere((line) => line.contains('exited'));

    await runtime.start(spec);
    process.finish(7);
    expect(await log, contains('code 7'));
    expect(runtime.isRunning, isFalse);
    expect(runtime.activeKind, isNull);
    await runtime.close();
  });
}

class _FakeProcess implements Process {
  final Completer<int> _exit = Completer<int>();

  bool killed = false;

  @override
  int get pid => 101;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
