import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

class SystemSchemeUtils {
  static const String _kKaringScheme = "karing";
  static const String _kClashScheme = "clash";
  static const String _kSingboxScheme = "sing-box";

  static String getKaringScheme() => _kKaringScheme;
  static String getClashScheme() => _kClashScheme;
  static String getSingboxScheme() => _kSingboxScheme;

  static String getKaringSchemeWith() => "$_kKaringScheme://";
  static String getClashSchemeWith() => "$_kClashScheme://";
  static String getSingboxSchemeWith() => "$_kSingboxScheme://";

  static bool isRegistered(String scheme) {
    return _isRegistered(scheme);
  }

  static Future<String?> register(String scheme) async {
    if (!Platform.isWindows) {
      return null;
    }
    final command = '"${Platform.resolvedExecutable}" "%1"';
    try {
      final key = CURRENT_USER.create('Software\\Classes\\$scheme');
      try {
        key.setValue('URL Protocol', RegistryValue.string(''));
        final commandKey = key.create('shell\\open\\command');
        try {
          commandKey.setValue('', RegistryValue.string(command));
        } finally {
          commandKey.close();
        }
      } finally {
        key.close();
      }
    } catch (err) {
      return err.toString();
    }
    return null;
  }

  static String? unregister(String scheme) {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final key = CURRENT_USER.open('Software\\Classes\\$scheme');
      try {
        key.removeTree();
      } finally {
        key.close();
      }
    } catch (err) {
      return err.toString();
    }
    return null;
  }

  static bool _isRegistered(String scheme) {
    if (!Platform.isWindows) {
      return false;
    }
    final appPath = Platform.resolvedExecutable.toLowerCase();
    try {
      final key = CURRENT_USER.open(
        'Software\\Classes\\$scheme\\shell\\open\\command',
      );
      try {
        final file = key.getString('');
        if (file == null) {
          return false;
        }
        return file.toLowerCase().indexOf(appPath) == 0;
      } finally {
        key.close();
      }
    } catch (err) {
      return false;
    }
  }
}
