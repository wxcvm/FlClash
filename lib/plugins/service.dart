import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final _utf8JsonDecoder = utf8.decoder.fuse(json.decoder);

Object? _decodeUtf8Json(Uint8List data) => _utf8JsonDecoder.convert(data);

Map<String, Object?> _decodeResponseOf((Uint8List, CoreMethod) request) {
  final (data, method) = request;
  final decoded = _decodeUtf8Json(data);
  return withResultModel(method, Map<String, Object?>.from(decoded as Map));
}

Future<Map<String, Object?>> _decodeResponse(
  Uint8List data,
  CoreMethod method,
) async {
  if (data.length < 51200) {
    return _decodeResponseOf((data, method));
  }
  return compute(_decodeResponseOf, (data, method));
}

abstract mixin class ServiceListener {
  void onServiceEvent(CoreEvent event) {}

  void onServiceStopped() {}
}

class Service {
  static Service? _instance;
  late MethodChannel methodChannel;
  static const _coreChannel = MethodChannel('$packageName/core');

  final ObserverList<ServiceListener> _listeners =
      ObserverList<ServiceListener>();

  final nativeStatus = ValueNotifier<AndroidNativeStatus?>(null);

  int _commandRevision = 0;
  bool _startRequested = false;

  factory Service() {
    _instance ??= Service._internal();
    return _instance!;
  }

  Service._internal() {
    methodChannel = const MethodChannel('$packageName/service');
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'event':
          final methodCall = CoreMethodCall.fromJson(
            Map<String, Object?>.from(
              _decodeUtf8Json(call.arguments as Uint8List) as Map,
            ),
          );
          for (final event in coreEventsFromData(methodCall.arguments)) {
            _dispatch(
              'Core event ${event.type.name}',
              (listener) => listener.onServiceEvent(event),
            );
          }
          break;
        case 'nativeCoreStatusChanged':
          nativeStatus.value = AndroidNativeStatus.fromMap(
            Map<Object?, Object?>.from(call.arguments as Map),
          );
          break;
        case 'stopped':
          // A report stamped before the newest command no longer describes it.
          if (call.arguments != _commandRevision || !_startRequested) {
            break;
          }
          _startRequested = false;
          _dispatch('stop report', (listener) => listener.onServiceStopped());
          break;
        default:
          throw MissingPluginException();
      }
    });
  }

  Future<CoreMethodResponse> invokeMethod(CoreMethodCall call) async {
    final data = await _coreChannel.invokeMethod<Uint8List>(
      'invokeMethod',
      json.encode(call),
    );
    if (data == null) {
      throw CoreMethodException(
        code: 'no_response',
        message: 'Core did not answer ${call.method.wireName}',
      );
    }
    return resolveSpilledResponse(
      CoreMethodResponse.fromJson(await _decodeResponse(data, call.method)),
      method: call.method,
    );
  }

  void _dispatch(String label, void Function(ServiceListener) deliver) {
    for (final listener in List.of(_listeners)) {
      try {
        deliver(listener);
      } catch (error) {
        commonPrint.log(
          'Unable to dispatch Android $label: $error',
          logLevel: LogLevel.error,
        );
      }
    }
  }

  Future<AndroidNativeStatus> getNativeStatus() async {
    final data = await methodChannel.invokeMapMethod<Object?, Object?>(
      'nativeCoreStatus',
    );
    final status = AndroidNativeStatus.fromMap(data ?? const {});
    nativeStatus.value = status;
    return status;
  }

  Future<Map<String, dynamic>> getNativeSnapshot() async {
    final json = await methodChannel.invokeMethod<String>('nativeSnapshot');
    return Map<String, dynamic>.from(jsonDecode(json ?? '{}') as Map);
  }

  Future<void> selectNativeOutbound(String group, String tag) async {
    await methodChannel.invokeMethod<bool>('selectNativeOutbound', {
      'group': group,
      'tag': tag,
    });
  }

  Future<void> testNativeOutbound(String tag) async {
    await methodChannel.invokeMethod<bool>('testNativeOutbound', {'tag': tag});
  }

  Future<String> validateNativeCore(String path) async =>
      await methodChannel.invokeMethod<String>('validateNativeCore', {
        'path': path,
      }) ??
      '';

  Future<AndroidNativeStartResult> startNativeCore(String path) async {
    final revision = ++_commandRevision;
    _startRequested = true;
    try {
      final data = await methodChannel.invokeMapMethod<Object?, Object?>(
        'startNativeCore',
        {'path': path, 'revision': revision},
      );
      return AndroidNativeStartResult.fromMap(data ?? const {});
    } finally {
      if (revision == _commandRevision) {
        final status = await getNativeStatus();
        if (revision == _commandRevision) {
          _startRequested = status.engine != 'idle' || status.nativeOwner;
        }
      }
    }
  }

  Future<bool> stopNativeCore() async {
    final revision = ++_commandRevision;
    _startRequested = false;
    try {
      return await methodChannel.invokeMethod<bool>(
            'stopNativeCore',
            {'revision': revision},
          ) ??
          false;
    } finally {
      if (revision == _commandRevision) {
        final status = await getNativeStatus();
        if (revision == _commandRevision) {
          _startRequested = status.engine != 'idle' || status.nativeOwner;
        }
      }
    }
  }

  Future<bool> start() async {
    _startRequested = true;
    return await methodChannel.invokeMethod<bool>(
          'start',
          ++_commandRevision,
        ) ??
        false;
  }

  Future<bool> stop() async {
    _startRequested = false;
    return await methodChannel.invokeMethod<bool>('stop', ++_commandRevision) ??
        false;
  }

  Future<String> init() async {
    return await methodChannel.invokeMethod<String>('init') ?? '';
  }

  Future<String> syncState(SharedState state) async {
    return await methodChannel.invokeMethod<String>(
          'syncState',
          json.encode(state),
        ) ??
        '';
  }

  Future<bool> shutdown() async {
    return await methodChannel.invokeMethod<bool>('shutdown') ?? true;
  }

  Future<DateTime?> getRunTime() async {
    final ms = await methodChannel.invokeMethod<int>('getRunTime') ?? 0;
    if (ms == 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void addListener(ServiceListener listener) {
    _listeners.add(listener);
  }

  void removeListener(ServiceListener listener) {
    _listeners.remove(listener);
  }
}

class AndroidNativeStatus {
  const AndroidNativeStatus({
    required this.available,
    required this.engine,
    required this.nativeOwner,
    required this.state,
  });

  factory AndroidNativeStatus.fromMap(Map<Object?, Object?> data) =>
      AndroidNativeStatus(
        available: data['available'] == true,
        engine: data['engine'] as String? ?? 'idle',
        nativeOwner: data['nativeOwner'] == true,
        state: data['state'] as String? ?? 'STOPPED',
      );

  final bool available;
  final String engine;
  final bool nativeOwner;
  final String state;
}

class AndroidNativeStartResult {
  const AndroidNativeStartResult({
    required this.started,
    required this.restoredMihomo,
    required this.error,
  });

  factory AndroidNativeStartResult.fromMap(Map<Object?, Object?> data) =>
      AndroidNativeStartResult(
        started: data['started'] == true,
        restoredMihomo: data['restoredMihomo'] == true,
        error: data['error'] as String? ?? '',
      );

  final bool started;
  final bool restoredMihomo;
  final String error;
}

Service? get service => system.isAndroid ? Service() : null;
