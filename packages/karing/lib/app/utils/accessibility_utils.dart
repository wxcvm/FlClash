import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class AccessibilityUtils {
  static bool _enabled = false;

  static bool getAccessibilityEnabled() => _enabled;

  static void setAccessibilityEnabled(bool value) {
    _enabled = value;
  }

  static void announce(BuildContext context, String message) {
    if (message.isEmpty) {
      return;
    }
    SemanticsService.announce(message, Directionality.maybeOf(context) ?? TextDirection.ltr);
  }
}
