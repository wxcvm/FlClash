import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A native core uses its own configuration and CLI, not FlClash's Mihomo IPC.
enum NativeCoreKind { singBox, xray, hysteria2 }

extension NativeCoreCommands on NativeCoreKind {
  String get label => switch (this) {
    NativeCoreKind.singBox => 'sing-box',
    NativeCoreKind.xray => 'Xray-core',
    NativeCoreKind.hysteria2 => 'Hysteria 2',
  };

  String get executableName => switch (this) {
    NativeCoreKind.singBox => 'sing-box',
    NativeCoreKind.xray => 'xray',
    NativeCoreKind.hysteria2 => 'hysteria',
  };

  List<String> checkArguments(String configPath) => switch (this) {
    NativeCoreKind.singBox => ['check', '-c', configPath],
    NativeCoreKind.xray => ['run', '-test', '-config', configPath],
    // Hysteria has no offline config check; version verifies the binary.
    NativeCoreKind.hysteria2 => ['version'],
  };

  List<String> runArguments(String configPath) => switch (this) {
    NativeCoreKind.singBox => ['run', '-c', configPath],
    NativeCoreKind.xray => ['run', '-config', configPath],
    NativeCoreKind.hysteria2 => ['client', '-c', configPath],
  };
}

final class NativeCoreSpec {
  final NativeCoreKind kind;
  final String executable;
  final String configPath;

  const NativeCoreSpec({
    required this.kind,
    required this.executable,
    required this.configPath,
  });

  String get absoluteConfigPath => p.absolute(configPath);

  String get workingDirectory => p.dirname(absoluteConfigPath);
}

final class NativeCoreValidation {
  final bool valid;
  final String details;

  const NativeCoreValidation({required this.valid, required this.details});
}

/// Emitted once when the owned child exits. A requested stop is not a crash.
final class NativeCoreExit {
  final NativeCoreKind kind;
  final int code;
  final bool expected;

  const NativeCoreExit({
    required this.kind,
    required this.code,
    required this.expected,
  });
}

typedef NativeCoreRun =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

typedef NativeCoreStart =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// Runs an optional desktop core with its native JSON or YAML configuration.
/// The application must coordinate network ownership before calling start().
/// It never changes system proxy, DNS or TUN settings on its own.
final class NativeCoreRuntime {
  final NativeCoreRun _run;
  final NativeCoreStart _start;
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<NativeCoreExit> _exits =
      StreamController<NativeCoreExit>.broadcast();
  Process? _process;
  NativeCoreKind? _activeKind;
  NativeCoreSpec? _activeSpec;
  bool _starting = false;
  bool _stopping = false;
  bool _nativeMode = false;

  NativeCoreRuntime({
    NativeCoreRun run = Process.run,
    NativeCoreStart start = Process.start,
  }) : _run = run,
       _start = start;

  Stream<String> get logs => _logs.stream;

  Stream<NativeCoreExit> get exits => _exits.stream;

  NativeCoreKind? get activeKind => _activeKind;

  NativeCoreSpec? get activeSpec => _activeSpec;

  bool get isRunning => _process != null;

  bool get blocksMihomoStart => _nativeMode || isRunning;

  /// Held by the handoff while a native process owns or is acquiring routes.
  void setNativeMode(bool active) => _nativeMode = active;

  Future<NativeCoreValidation> validate(NativeCoreSpec spec) async {
    if (!await File(spec.absoluteConfigPath).exists()) {
      return NativeCoreValidation(
        valid: false,
        details: 'Config file not found: ${spec.absoluteConfigPath}',
      );
    }
    // Hysteria uses YAML rather than Mihomo/sing-box/Xray JSON. Its CLI
    // has no offline config-check subcommand, so verify basic YAML here and
    // use the harmless version command to verify the executable.
    if (spec.kind == NativeCoreKind.hysteria2) {
      try {
        final yaml = loadYaml(
          await File(spec.absoluteConfigPath).readAsString(),
        );
        if (yaml is! YamlMap ||
            yaml['server'] is! String ||
            (yaml['server'] as String).trim().isEmpty) {
          return const NativeCoreValidation(
            valid: false,
            details: 'Hysteria client YAML needs a server address',
          );
        }
      } on Exception catch (error) {
        return NativeCoreValidation(valid: false, details: error.toString());
      }
    }
    try {
      final result = await _run(
        spec.executable,
        spec.kind.checkArguments(spec.absoluteConfigPath),
        workingDirectory: spec.workingDirectory,
      );
      final details = [
        result.stdout.toString().trim(),
        result.stderr.toString().trim(),
      ].where((line) => line.isNotEmpty).join('\n');
      return NativeCoreValidation(
        valid: result.exitCode == 0,
        details: spec.kind == NativeCoreKind.hysteria2
            ? 'YAML syntax checked; native settings checked at startup\n$details'
            : details,
      );
    } on ProcessException catch (error) {
      return NativeCoreValidation(valid: false, details: error.toString());
    }
  }

  Future<void> start(NativeCoreSpec spec) async {
    if (_starting || _stopping || _process != null) {
      throw StateError('A native core is already running or changing state');
    }
    _starting = true;
    try {
      final check = await validate(spec);
      if (!check.valid) {
        throw StateError('${spec.kind.label}: ${check.details}');
      }
      final process = await _start(
        spec.executable,
        spec.kind.runArguments(spec.absoluteConfigPath),
        workingDirectory: spec.workingDirectory,
      );
      _process = process;
      _activeKind = spec.kind;
      _activeSpec = spec;
      // External programs may emit non-UTF-8 diagnostics on Windows.
      // A malformed log byte must not become an unhandled stream error.
      const decoder = Utf8Decoder(allowMalformed: true);
      process.stdout.transform(decoder).listen(_emitLog);
      process.stderr.transform(decoder).listen(_emitLog);
      _emitLog('${spec.kind.label} started (PID ${process.pid})');
      unawaited(
        process.exitCode.then((code) {
          if (identical(_process, process)) {
            _process = null;
            _activeKind = null;
            _activeSpec = null;
            if (!_exits.isClosed) {
              _exits.add(
                NativeCoreExit(
                  kind: spec.kind,
                  code: code,
                  expected: _stopping,
                ),
              );
            }
          }
          _emitLog('${spec.kind.label} exited with code $code');
        }),
      );
    } finally {
      _starting = false;
    }
  }

  Future<void> stop({Duration timeout = const Duration(seconds: 5)}) async {
    if (_starting) {
      throw StateError('Native core is still starting');
    }
    if (_stopping) {
      throw StateError('Native core is already stopping');
    }
    final process = _process;
    if (process == null) return;
    _stopping = true;
    try {
      process.kill();
      await process.exitCode.timeout(timeout);
      if (identical(_process, process)) {
        _process = null;
        _activeKind = null;
        _activeSpec = null;
      }
    } finally {
      _stopping = false;
    }
  }

  void _emitLog(String message) {
    if (!_logs.isClosed) _logs.add(message);
  }

  Future<void> close() async {
    await stop();
    if (!_logs.isClosed) await _logs.close();
    if (!_exits.isClosed) await _exits.close();
  }
}

/// A desktop-scoped runtime, shared across settings pages and stopped on exit.
final nativeCoreRuntime = NativeCoreRuntime();
