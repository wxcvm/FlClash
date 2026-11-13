import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';

import '../helpers/app_paths.dart';

class _RecordingListener with ServiceListener {
  final events = <CoreEvent>[];

  @override
  void onServiceEvent(CoreEvent event) => events.add(event);
}

class _RecordingStopListener with ServiceListener {
  var stops = 0;

  @override
  void onServiceStopped() => stops++;
}

class _ThrowingListener with ServiceListener {
  var called = false;

  @override
  void onServiceEvent(CoreEvent event) {
    called = true;
    throw StateError('listener boom');
  }

  @override
  void onServiceStopped() {
    throw StateError('listener boom');
  }
}

class _MutatingListener with ServiceListener {
  final ServiceListener target;

  _MutatingListener(this.target);

  @override
  void onServiceEvent(CoreEvent event) {
    Service().removeListener(target);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = '$packageName/service';
  const channel = MethodChannel(channelName);
  const coreChannel = MethodChannel('$packageName/core');
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;

  void mockChannel(
    Future<Object?>? Function(MethodCall call) handler, {
    MethodChannel target = channel,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(target, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  void mockCoreChannel(Future<Object?>? Function(MethodCall call) handler) =>
      mockChannel(handler, target: coreChannel);

  Future<void> emitFromPlatform(Object? arguments) async {
    final payload = json.encode(
      CoreMethodCall(method: CoreMethod.message, arguments: arguments).toJson(),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channelName,
          codec.encodeMethodCall(MethodCall('event', utf8.encode(payload))),
          null,
        );
  }

  setUp(() {
    calls = <MethodCall>[];
    Service().nativeStatus.value = null;
  });

  tearDown(() {
    for (final target in [channel, coreChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(target, null);
    }
  });

  test('is a singleton so the platform handler is installed once', () {
    expect(Service(), same(Service()));
  });

  group('native ownership', () {
    const native = {
      'available': true,
      'engine': 'sing-box',
      'nativeOwner': true,
      'mihomoSuspended': true,
      'startedAt': 1234,
      'state': 'STARTED',
    };

    Future<void> emitStatus(Map<String, Object?> status) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            codec.encodeMethodCall(
              MethodCall('nativeCoreStatusChanged', status),
            ),
            null,
          );
    }

    test(
      'native ownership blocks Mihomo traffic before any channel call',
      () async {
        await emitStatus(native);
        expect(Service().nativeOwnsRuntime, isTrue);
        await expectLater(
          Service().invokeMethod(
            const CoreMethodCall(method: CoreMethod.trafficCurrent),
          ),
          throwsA(
            isA<CoreMethodException>().having(
              (e) => e.code,
              'code',
              'core_unavailable',
            ),
          ),
        );
        expect(calls, isEmpty);
        await emitStatus({'engine': 'mihomo', 'state': 'STARTED'});
        mockCoreChannel(
          (_) async => utf8.encode(
            json.encode(
              const CoreMethodResponse(id: '1', result: {'up': 1}).toJson(),
            ),
          ),
        );
        final result = await Service().invokeMethod(
          const CoreMethodCall(id: '1', method: CoreMethod.trafficCurrent),
        );
        expect(result.result, {'up': 1});
        expect(calls.single.method, 'invokeMethod');
      },
    );

    test('an old status read cannot overwrite a newer native event', () async {
      final response = Completer<Object?>();
      mockChannel((_) => response.future);
      final pending = Service().getNativeStatus();
      await emitStatus(native);
      response.complete({'engine': 'mihomo', 'state': 'STARTED'});
      expect((await pending).engine, 'sing-box');
      expect(Service().nativeStatus.value?.engine, 'sing-box');
    });

    test('only the latest overlapping status read updates ownership', () async {
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      mockChannel((_) => calls.length == 1 ? first.future : second.future);
      final a = Service().getNativeStatus();
      final b = Service().getNativeStatus();
      second.complete(native);
      expect((await b).engine, 'sing-box');
      first.complete({'engine': 'idle', 'state': 'STOPPED'});
      expect((await a).engine, 'sing-box');
      expect(Service().nativeOwnsRuntime, isTrue);
    });

    test('cleanup and suspended state remain owned without a runtime', () {
      expect(
        AndroidNativeStatus.fromMap({
          'engine': 'idle',
          'nativeOwner': true,
        }).ownsRuntime,
        isTrue,
      );
      expect(
        AndroidNativeStatus.fromMap({
          'engine': 'idle',
          'mihomoSuspended': true,
        }).ownsRuntime,
        isTrue,
      );
      expect(
        AndroidNativeStatus.fromMap({'engine': 'idle'}).ownsRuntime,
        isFalse,
      );
    });

    test('native overview uses the status-only command', () async {
      mockChannel((_) async => '{"status":{"upload":17},"rateAvailable":true}');
      final result = await Service().getNativeStatusSnapshot();
      expect(result['status']['upload'], 17);
      expect(calls.single.method, 'nativeStatusSnapshot');
    });
  });

  group('native runtime commands', () {
    test('quality and snapshot commands preserve their payloads', () async {
      mockChannel((call) async {
        return switch (call.method) {
          'nativeQualitySnapshot' => '{"state":"done","downloadBps":123}',
          'nativeSnapshot' => '{"networkReady":true,"generation":7}',
          'validateNativeCore' => '1.14.4',
          _ => true,
        };
      });

      final service = Service();
      await service.startNativeQuality('HK');
      expect(await service.getNativeQuality(), {
        'state': 'done',
        'downloadBps': 123,
      });
      await service.cancelNativeQuality();
      expect(await service.getNativeSnapshot(), {
        'networkReady': true,
        'generation': 7,
      });
      await service.resetNativeNetwork();
      await service.selectNativeOutbound('auto', 'HK', generation: 7);
      await service.testNativeOutbound('HK');
      expect(await service.validateNativeCore('/profile.json'), '1.14.4');

      expect(calls.map((call) => call.method), [
        'startNativeQuality',
        'nativeQualitySnapshot',
        'cancelNativeQuality',
        'nativeSnapshot',
        'resetNativeNetwork',
        'selectNativeOutbound',
        'testNativeOutbound',
        'validateNativeCore',
      ]);
      expect(calls[0].arguments, {'tag': 'HK'});
      expect(calls[5].arguments, {
        'group': 'auto',
        'tag': 'HK',
        'generation': 7,
      });
      expect(calls[6].arguments, {'tag': 'HK'});
      expect(calls[7].arguments, {'path': '/profile.json'});
    });

    test('native start, switch and stop refresh actual ownership', () async {
      var engine = 'idle';
      mockChannel((call) async {
        switch (call.method) {
          case 'startNativeCore':
            engine = 'sing-box';
            return {'started': true, 'restoredMihomo': false, 'error': ''};
          case 'startMihomoCore':
            engine = 'mihomo';
            return true;
          case 'stopNativeCore':
            engine = 'idle';
            return true;
          case 'nativeCoreStatus':
            return {'engine': engine, 'available': true};
          default:
            throw StateError('Unexpected command: ${call.method}');
        }
      });

      final service = Service();
      final started = await service.startNativeCore('/profile.json');
      expect(started.started, isTrue);
      expect(started.restoredMihomo, isFalse);
      expect(started.error, isEmpty);
      expect(service.nativeOwnsRuntime, isTrue);
      expect(await service.startMihomoCore(), isTrue);
      expect(service.nativeStatus.value?.engine, 'mihomo');
      expect(service.nativeOwnsRuntime, isFalse);
      expect(await service.stopNativeCore(), isTrue);
      expect(service.nativeStatus.value?.engine, 'idle');

      expect(calls.map((call) => call.method), [
        'startNativeCore',
        'nativeCoreStatus',
        'startMihomoCore',
        'nativeCoreStatus',
        'stopNativeCore',
        'nativeCoreStatus',
      ]);
      final startArgs = calls[0].arguments as Map;
      final switchArgs = calls[2].arguments as Map;
      final stopArgs = calls[4].arguments as Map;
      expect(startArgs['path'], '/profile.json');
      expect(switchArgs['revision'], greaterThan(startArgs['revision']));
      expect(stopArgs['revision'], greaterThan(switchArgs['revision']));
    });

    test('failed native start reports restored Mihomo and error', () async {
      mockChannel((call) async {
        return switch (call.method) {
          'startNativeCore' => {
            'started': false,
            'restoredMihomo': true,
            'error': 'invalid configuration',
          },
          'nativeCoreStatus' => {'engine': 'mihomo'},
          _ => null,
        };
      });

      final result = await Service().startNativeCore('/invalid.json');
      expect(result.started, isFalse);
      expect(result.restoredMihomo, isTrue);
      expect(result.error, 'invalid configuration');
      expect(Service().nativeStatus.value?.engine, 'mihomo');
      expect(Service().nativeOwnsRuntime, isFalse);
    });

    test('missing native command results do not report success', () async {
      mockChannel((_) async => null);
      final service = Service();

      expect((await service.startNativeCore('/profile.json')).started, isFalse);
      expect(await service.startMihomoCore(), isFalse);
      expect(await service.stopNativeCore(), isFalse);
      expect(service.nativeOwnsRuntime, isFalse);
      expect(await service.validateNativeCore('/profile.json'), isEmpty);
      expect(await service.getNativeQuality(), isEmpty);
      expect(await service.getNativeSnapshot(), isEmpty);
    });

    test('a late native start cannot replace a newer stop intent', () async {
      final start = Completer<Object?>();
      mockChannel((call) {
        return switch (call.method) {
          'startNativeCore' => start.future,
          'stopNativeCore' => Future.value(true),
          'nativeCoreStatus' => Future.value({'engine': 'idle'}),
          _ => throw StateError('Unexpected command: ${call.method}'),
        };
      });

      final service = Service();
      final pending = service.startNativeCore('/profile.json');
      expect(await service.stopNativeCore(), isTrue);
      start.complete({'started': true});
      await pending;

      expect(service.nativeStatus.value?.engine, 'idle');
      expect(service.nativeOwnsRuntime, isFalse);
      expect(calls.map((call) => call.method), [
        'startNativeCore',
        'stopNativeCore',
        'nativeCoreStatus',
      ]);
    });
  });

  group('lifecycle commands', () {
    test('start and stop report the platform result', () async {
      mockChannel((call) async => call.method == 'start');

      expect(await Service().start(), isTrue);
      expect(await Service().stop(), isFalse);
      expect(calls.map((call) => call.method), ['start', 'stop']);
    });

    test('an absent start or stop result is treated as failure', () async {
      mockChannel((_) async => null);

      expect(await Service().start(), isFalse);
      expect(await Service().stop(), isFalse);
    });

    test('an absent shutdown result is treated as success', () async {
      mockChannel((_) async => null);

      expect(
        await Service().shutdown(),
        isTrue,
        reason:
            'shutdown defaults the opposite way from start/stop: a service '
            'that cannot answer is already gone',
      );
    });

    test('init and syncState fall back to an empty payload', () async {
      mockChannel((_) async => null);

      expect(await Service().init(), isEmpty);
      expect(
        await Service().syncState(
          const SharedState(
            stopTip: 'stopTip',
            startTip: 'startTip',
            localNetworkTip: 'localNetworkTip',
            currentProfileName: 'profile',
            stopText: 'stop',
            onlyStatisticsProxy: false,
          ),
        ),
        isEmpty,
      );
    });

    test('syncState sends the encoded shared state', () async {
      mockChannel((_) async => 'ok');
      const state = SharedState(
        stopTip: 'stopTip',
        startTip: 'startTip',
        localNetworkTip: 'localNetworkTip',
        currentProfileName: 'profile',
        stopText: 'stop',
        onlyStatisticsProxy: true,
      );

      expect(await Service().syncState(state), 'ok');

      final sent = json.decode(calls.single.arguments as String);
      expect(sent['currentProfileName'], 'profile');
      expect(sent['onlyStatisticsProxy'], isTrue);
      expect(sent, isNot(contains('setupParams')));
    });
  });

  group('stop reports', () {
    late _RecordingStopListener listener;

    Future<void> reportStopped(Object? revision) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            codec.encodeMethodCall(MethodCall('stopped', revision)),
            null,
          );
    }

    int lastRevision() => calls.last.arguments as int;

    setUp(() {
      mockChannel((_) async => true);
      listener = _RecordingStopListener();
      Service().addListener(listener);
    });

    tearDown(() => Service().removeListener(listener));

    test('every command carries a revision newer than the last', () async {
      await Service().start();
      final first = lastRevision();
      await Service().stop();

      expect(lastRevision(), greaterThan(first));
    });

    test(
      'a report for the start in force reaches the listeners once',
      () async {
        await Service().start();

        await reportStopped(lastRevision());
        await reportStopped(lastRevision());

        expect(listener.stops, 1);
      },
    );

    test('a report older than the newest command is dropped', () async {
      await Service().start();
      final stale = lastRevision();
      await Service().stop();
      await Service().start();

      await reportStopped(stale);

      expect(listener.stops, 0);
    });

    test(
      'a report is dropped while Flutter itself asked for the stop',
      () async {
        await Service().start();
        await Service().stop();

        await reportStopped(lastRevision());

        expect(listener.stops, 0);
      },
    );

    test('a throwing listener does not starve the next one', () async {
      final throwing = _ThrowingListener();
      Service().removeListener(listener);
      Service().addListener(throwing);
      Service().addListener(listener);
      addTearDown(() => Service().removeListener(throwing));
      await Service().start();

      await reportStopped(lastRevision());

      expect(listener.stops, 1);
    });
  });

  group('getRunTime', () {
    test('maps a millisecond stamp to a DateTime', () async {
      final stamp = DateTime.utc(2026, 8, 16).millisecondsSinceEpoch;
      mockChannel((_) async => stamp);

      expect(
        await Service().getRunTime(),
        DateTime.fromMillisecondsSinceEpoch(stamp),
      );
    });

    test('treats zero and a missing stamp as not running', () async {
      mockChannel((_) async => 0);
      expect(await Service().getRunTime(), isNull);

      mockChannel((_) async => null);
      expect(await Service().getRunTime(), isNull);
    });
  });

  group('invokeMethod', () {
    test('encodes the call and decodes the response envelope', () async {
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode(
            const CoreMethodResponse(id: '7', result: {'up': 1}).toJson(),
          ),
        ),
      );

      final response = await Service().invokeMethod(
        const CoreMethodCall(
          id: '7',
          method: CoreMethod.trafficCurrent,
          arguments: true,
        ),
      );

      final sent =
          json.decode(calls.single.arguments as String) as Map<String, Object?>;
      expect(calls.single.method, 'invokeMethod');
      expect(sent['id'], '7');
      expect(sent['method'], CoreMethod.trafficCurrent.wireName);
      expect(
        sent['arguments'],
        isTrue,
        reason: 'arguments stay structured JSON, never a pre-encoded string',
      );
      expect(response.id, '7');
      expect(response.result, {'up': 1});
      expect(response.error, isNull);
    });

    test('decodes a large UTF-8 envelope off the calling isolate', () async {
      final names = List.generate(5000, (index) => '节点-$index');
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode(CoreMethodResponse(id: '3', result: names).toJson()),
        ),
      );

      final response = await Service().invokeMethod(
        const CoreMethodCall(id: '3', method: CoreMethod.proxyList),
      );

      expect(response.result, names);
    });

    test('reads an envelope the Core spilled to a file', () async {
      final home = Directory.systemTemp.createTempSync('service_spill');
      addTearDown(() => home.deleteSync(recursive: true));
      await useAppPaths(home);
      final file = File(join(home.path, coreSpillDirectoryName, '1.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          json.encode(
            const CoreMethodResponse(id: '8', result: 'big').toJson(),
          ),
        );
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode(CoreMethodResponse(id: '8', file: file.path).toJson()),
        ),
      );

      final response = await Service().invokeMethod(
        const CoreMethodCall(id: '8', method: CoreMethod.configRead),
      );

      expect(response.result, 'big');
      expect(file.existsSync(), isFalse);
    });

    test('fails when the platform sends no envelope', () async {
      mockCoreChannel((_) async => null);

      await expectLater(
        Service().invokeMethod(
          const CoreMethodCall(method: CoreMethod.trafficCurrent),
        ),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'no_response',
          ),
        ),
      );
    });

    test('surfaces a Core error inside the envelope', () async {
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode({
            'id': '1',
            'result': null,
            'error': {'code': 'unavailable', 'message': 'core down'},
          }),
        ),
      );

      final response = await Service().invokeMethod(
        const CoreMethodCall(id: '1', method: CoreMethod.trafficCurrent),
      );

      expect(response.error, isNotNull);
      expect(response.error!.code, 'unavailable');
      expect(response.error!.message, 'core down');
    });
  });

  group('event dispatch', () {
    test('fans a batched event list out to every listener', () async {
      final first = _RecordingListener();
      final second = _RecordingListener();
      Service().addListener(first);
      Service().addListener(second);
      addTearDown(() {
        Service().removeListener(first);
        Service().removeListener(second);
      });

      await emitFromPlatform([
        {'type': CoreEventType.crash.name, 'data': 'boom'},
        {'type': CoreEventType.loaded.name, 'data': 'provider'},
      ]);

      for (final listener in [first, second]) {
        expect(listener.events.map((event) => event.type), [
          CoreEventType.crash,
          CoreEventType.loaded,
        ]);
        expect(listener.events.first.data, 'boom');
      }
    });

    test('accepts a single event object as well as a list', () async {
      final listener = _RecordingListener();
      Service().addListener(listener);
      addTearDown(() => Service().removeListener(listener));

      await emitFromPlatform({
        'type': CoreEventType.crash.name,
        'data': 'boom',
      });

      expect(listener.events.single.type, CoreEventType.crash);
    });

    test('a throwing listener does not starve the others', () async {
      final throwing = _ThrowingListener();
      final healthy = _RecordingListener();
      Service().addListener(throwing);
      Service().addListener(healthy);
      addTearDown(() {
        Service().removeListener(throwing);
        Service().removeListener(healthy);
      });

      await emitFromPlatform([
        {'type': CoreEventType.crash.name, 'data': 'boom'},
      ]);

      expect(throwing.called, isTrue);
      expect(healthy.events.single.type, CoreEventType.crash);
    });

    test('mutating listeners during dispatch does not throw', () async {
      final second = _RecordingListener();
      final mutating = _MutatingListener(second);
      Service().addListener(mutating);
      Service().addListener(second);
      addTearDown(() {
        Service().removeListener(mutating);
        Service().removeListener(second);
      });

      await expectLater(
        emitFromPlatform([
          {'type': CoreEventType.crash.name, 'data': 'boom'},
        ]),
        completes,
      );
    });

    test('an unparsable event is dropped without losing the batch', () async {
      final listener = _RecordingListener();
      Service().addListener(listener);
      addTearDown(() => Service().removeListener(listener));

      await emitFromPlatform([
        {'type': 'notAnEventType'},
        {'type': CoreEventType.crash.name, 'data': 'boom'},
      ]);

      expect(listener.events.single.type, CoreEventType.crash);
    });

    test('a removed listener stops receiving events', () async {
      final listener = _RecordingListener();
      Service().addListener(listener);
      expect(Service().hasListeners, isTrue);
      Service().removeListener(listener);
      expect(Service().hasListeners, isFalse);

      await emitFromPlatform([
        {'type': CoreEventType.crash.name, 'data': 'boom'},
      ]);

      expect(listener.events, isEmpty);
    });

    test('an unknown platform method is reported as unimplemented', () async {
      final unknown = await TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            codec.encodeMethodCall(const MethodCall('nope')),
            null,
          );
      final known = await TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            codec.encodeMethodCall(MethodCall('event', Uint8List(0))),
            null,
          );

      expect(
        unknown,
        isNull,
        reason:
            'the handler throws MissingPluginException, which a method channel '
            'answers with a null reply rather than an error envelope',
      );
      expect(known, isNotNull);
    });
  });
}
