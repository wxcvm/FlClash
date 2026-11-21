import 'package:android_package_manager/src/entities/impl/package_info.dart';
export 'package:android_package_manager/src/entities/impl/package_info.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PackageInfoEx {
  PackageInfo info = PackageInfoImpl(<String, dynamic>{});
  String name = '';
  Image? icon;
}

class PackageManagerAndroid {
  static const int kAndroidFlagSystem = 1;
  static const String kRemoved = '(removed)';
  static const _channel = MethodChannel('karing/package_manager');

  static Future<List<PackageInfoEx>> getInstalledPackages({
    bool Function(PackageInfo info)? onValid,
  }) async {
    try {
      final raw = await _channel.invokeListMethod('getInstalledPackages');
      if (raw == null) return [];
      final items = <PackageInfoEx>[];
      for (final element in raw) {
        if (element is! Map) continue;
        final map = Map<String, dynamic>.from(element);
        final info = PackageInfoImpl(map);
        if (onValid != null && !onValid(info)) continue;
        final item = PackageInfoEx()..info = info;
        item.name = info.packageName ?? '';
        items.add(item);
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<Image?> getInstalledPackageIcon(
    List<PackageInfoEx> packages,
    String packageName,
  ) async {
    for (final package in packages) {
      if (package.info.packageName == packageName) {
        return package.icon;
      }
    }
    return null;
  }

  static int sortByName(PackageInfoEx a, PackageInfoEx b) {
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
