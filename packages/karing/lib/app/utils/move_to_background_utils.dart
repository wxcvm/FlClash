import 'dart:io';

import 'package:flutter/services.dart';

class MoveToBackgroundUtils {
  static const _channel = MethodChannel('karing/move_to_background');

  static Future<void> moveToBackground({Duration? duration}) async {
    if (duration != null) {
      await Future<void>.delayed(duration);
    }
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('moveToBackground');
    } catch (_) {}
  }
}
