import 'dart:io';

import 'package:fl_clash/core/desktop/process_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the current process is alive', () async {
    expect(await isProcessAlive(pid), isTrue);
  });

  test('an exited child process is not alive', () async {
    final process = await Process.start(
      Platform.isWindows ? 'cmd' : 'sh',
      Platform.isWindows ? ['/c', 'exit 0'] : ['-c', 'exit 0'],
    );
    await process.exitCode;

    expect(await isProcessAlive(process.pid), isFalse);
  });

  test('Linux proc stat handles embedded closing parentheses', () {
    expect(
      linuxProcStatIndicatesAlive('123 (worker) with ) chars) S 1 2'),
      isTrue,
    );
    expect(
      linuxProcStatIndicatesAlive('123 (worker) with ) chars) Z 1 2'),
      isFalse,
    );
    expect(linuxProcStatIndicatesAlive('123 (worker) X 1 2'), isFalse);
    expect(linuxProcStatIndicatesAlive('123 (worker) x 1 2'), isFalse);
  });

  test('Linux proc stat mismatched PID is inconclusive', () {
    expect(
      linuxProcStatIndicatesAlive('456 (worker) Z 1 2', expectedPid: 123),
      isTrue,
    );
    expect(
      linuxProcStatIndicatesAlive('123 (worker) Z 1 2', expectedPid: 123),
      isFalse,
    );
    expect(
      linuxProcStatIndicatesAlive('123 (worker) S 1 2', expectedPid: 123),
      isTrue,
    );
  });

  test('inconclusive Linux proc stat is never mistaken for exit', () {
    expect(linuxProcStatIndicatesAlive(''), isTrue);
    expect(linuxProcStatIndicatesAlive('malformed'), isTrue);
    expect(linuxProcStatIndicatesAlive('123 (worker) '), isTrue);
    // A damaged header or state field must not release core ownership.
    expect(linuxProcStatIndicatesAlive('garbled (worker) Z 1 2'), isTrue);
    expect(linuxProcStatIndicatesAlive('123 worker) Z 1 2'), isTrue);
    expect(linuxProcStatIndicatesAlive('123 (worker)Z 1 2'), isTrue);
    expect(linuxProcStatIndicatesAlive('123 (worker) Zgarbled'), isTrue);
  });

  test('only Linux ENOENT proves a missing proc stat entry', () {
    expect(
      linuxProcStatIsMissing(
        const FileSystemException(
          'missing',
          '/proc/123/stat',
          OSError('ENOENT', 2),
        ),
      ),
      isTrue,
    );
    expect(
      linuxProcStatIsMissing(
        const FileSystemException(
          'denied',
          '/proc/123/stat',
          OSError('EACCES', 13),
        ),
      ),
      isFalse,
    );
    expect(
      linuxProcStatIsMissing(const FileSystemException('unknown')),
      isFalse,
    );
  });

  test('non-positive pids are never alive', () async {
    expect(await isProcessAlive(0), isFalse);
    expect(await isProcessAlive(-1), isFalse);
  });
}
