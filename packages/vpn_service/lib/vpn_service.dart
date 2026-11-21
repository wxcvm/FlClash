import 'dart:io';

import 'proxy_manager.dart';
import 'state.dart';
import 'vpn_service_platform_interface.dart';

abstract final class FlutterVpnService {
  // 桥接 FlClash 核心 TODO：由宿主接管状态、命令及系统代理所有权。
  static const _unavailable = 'FlClash VPN bridge is not connected.';

  static Future<void> init() async {}

  static Future<FlutterVpnServiceState> get currentState async =>
      FlutterVpnServiceState.disconnected;

  static void onStateChanged(
    void Function(FlutterVpnServiceState, Map<String, String>) callback,
  ) {}

  static void prepareConfig({
    required VpnServiceConfig config,
    required String tunnelServicePath,
    required String configFilePath,
    required bool systemExtension,
    required String bundleIdentifier,
    required String uiServerAddress,
    required String uiLocalizedDescription,
    required List<int> excludePorts,
  }) {}

  static Future<VpnServiceWaitResult> start(Duration timeout) async =>
      VpnServiceWaitResult(
        VpnServiceWaitType.error,
        err: VpnServiceResultError(_unavailable),
      );

  static Future<VpnServiceWaitResult> startVpnService(Duration timeout) =>
      start(timeout);

  static Future<VpnServiceWaitResult> restart(Duration timeout) =>
      start(timeout);

  static Future<void> stop() async {}

  static Future<VpnServiceResultError?> installService() async =>
      VpnServiceResultError(_unavailable);

  static Future<VpnServiceResultError?> uninstallService() async =>
      VpnServiceResultError(_unavailable);

  static Future<VpnServiceResultError?> reload() async =>
      VpnServiceResultError(_unavailable);

  static Future<bool> getSystemProxyEnable(ProxyOption option) async => false;

  static Future<void> setSystemProxy(ProxyOption option) async =>
      throw UnimplementedError(_unavailable);

  static Future<void> cleanSystemProxy() async {}

  static void firewallAddApp(String appPath, String appName) {}

  static void firewallAddPorts(List<int> ports, String appName) {}

  static Future<bool> isRunAsAdmin() async => false;

  static Future<String> getABIs() async => '[]';

  static Future<String> getSystemVersion() async =>
      Platform.operatingSystemVersion;

  static Future<void> setAlwaysOn(bool enable) async {}

  static Future<String?> setExcludeFromRecents(bool exclude) async =>
      _unavailable;

  static void hideDockIcon(bool hide) {}

  static Future<bool> isServiceAuthorized(String servicePath) async => false;

  static Future<VpnServiceResultError?> authorizeService(
    String servicePath,
    String password,
  ) async => VpnServiceResultError(_unavailable);

  static Future<Directory?> getAppGroupDirectory(String groupId) async => null;

  static Future<String> clashiApiConnections(bool close) async =>
      '{"connections":[]}';

  static Future<void> autoStartCreate(
    String taskName,
    String executable, {
    required String processArgs,
    required bool runElevated,
  }) async => throw UnimplementedError(_unavailable);

  static Future<void> autoStartDelete(String taskName) async {}

  static Future<bool> autoStartIsActive(String taskName) async => false;
}
