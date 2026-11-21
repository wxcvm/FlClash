// ignore_for_file: unused_catch_stack

import 'dart:io';

import 'package:karing/app/utils/path_utils.dart';
import 'package:win32_registry/win32_registry.dart';

abstract final class AppRegistryUtils {
  static const String _registryPath = 'Software\\Karing';
  static const String _registryValueNameDid = 'did';
  static String? getDid() {
    return _getAsString(_registryValueNameDid);
  }

  static void saveDid(String did) {
    _saveAsString(_registryValueNameDid, did);
  }

  static String? _getAsString(String name) {
    if (!Platform.isWindows) {
      return null;
    }
    if (PathUtils.portableMode()) {
      return null;
    }

    try {
      final key = CURRENT_USER.open(_registryPath);
      try {
        return key.getString(name);
      } finally {
        key.close();
      }
    } catch (err) {}
    return null;
  }

  static void _saveAsString(String name, String value) {
    if (!Platform.isWindows) {
      return;
    }
    if (PathUtils.portableMode()) {
      return;
    }
    try {
      final key = CURRENT_USER.create(_registryPath);
      try {
        key.setValue(name, RegistryValue.string(value));
      } finally {
        key.close();
      }
    } catch (err) {}
  }
}
