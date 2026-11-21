import 'package:flutter/widgets.dart';

class MacosProcessInfo {
  String identifier = '';
  String name = '';
  bool hasIcon = false;

  MacosProcessInfo({required this.identifier, required this.name});
}

class ProcessUtilsMacos {
  static Future<List<MacosProcessInfo>> getProcessList() async {
    return [];
  }

  static Future<Image?> getProcessIcon(
    List<MacosProcessInfo> processInfoList,
    String process,
  ) async {
    return null;
  }
}
