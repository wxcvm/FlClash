// ignore_for_file: unused_catch_stack

import 'dart:io';

class PlatformUtils {
  static bool get windows => Platform.isWindows;
  static bool get macos => Platform.isMacOS;
  static bool get linux => Platform.isLinux;
  static bool get android => Platform.isAndroid;
  static bool get ios => Platform.isIOS;
  static bool isPC() {
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  }

  static bool isMobile() {
    return Platform.isAndroid || Platform.isIOS;
  }

  static bool maybeTV() {
    if (Platform.isAndroid) {
      return true;
    }
    return false;
  }
}
