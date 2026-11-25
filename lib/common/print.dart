import 'package:dio/dio.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';

/// Removes credentials from application and core log payloads before storage/export.
String redactSensitiveLogText(String value) {
  var text = value;
  text = text.replaceAll(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^\s/@]+@', caseSensitive: false),
    r'$1[REDACTED]@',
  );
  text = text.replaceAll(
    RegExp(
      r'([?&](?:access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|key|secret|password|passwd|authorization|auth|credential|uuid|subscription(?:[_-]?token)?)=)[^&#\s]*',
      caseSensitive: false,
    ),
    r'$1[REDACTED]',
  );
  text = text.replaceAll(
    RegExp(
      r'(\bauthorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s,;]+',
      caseSensitive: false,
    ),
    r'$1[REDACTED]',
  );
  text = text.replaceAll(
    RegExp(
      r'''(\b(?:password|passwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|secret|private[_-]?key|pre[_-]?shared[_-]?key|psk|auth(?:[_-]?str)?|authorization|uuid)\b\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    r'$1[REDACTED]',
  );
  text = text.replaceAll(
    RegExp(r'\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    '[REDACTED_AUTH]',
  );
  text = text.replaceAll(
    RegExp(
      r'\b(?:vmess|vless|trojan|ss|ssr|hysteria|hysteria2|hy2|tuic|wireguard)://\S+',
      caseSensitive: false,
    ),
    '[REDACTED_PROXY_LINK]',
  );
  text = text.replaceAll(
    RegExp(r'\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b'),
    '[REDACTED_UUID]',
  );
  return text;
}

String compactError(Object error) {
  if (error is DioException) {
    final statusCode = error.response?.statusCode;
    return statusCode != null
        ? 'DioException(${error.type.name}, HTTP $statusCode)'
        : 'DioException(${error.type.name})';
  }
  return redactSensitiveLogText(error.toString());
}

class CommonPrint {
  static CommonPrint? _instance;

  CommonPrint._internal();

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  void log(String? text, {LogLevel logLevel = LogLevel.info}) {
    final payload = redactSensitiveLogText('[APP] $text');
    debugPrint(payload);
    if (!globalState.isAttach) {
      return;
    }
    globalState.container
        .read(logsProvider.notifier)
        .add(Log.app(payload).copyWith(logLevel: logLevel));
  }
}

final commonPrint = CommonPrint();
