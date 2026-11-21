import 'dart:io';

class SystemUtils {
  static Future<String> getRouteTable() async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('route', ['print']);
        return (result.stdout ?? '').toString();
      }
      final result = await Process.run('netstat', ['-rn']);
      return (result.stdout ?? '').toString();
    } catch (e) {
      return 'getRouteTable failed: $e';
    }
  }
}
