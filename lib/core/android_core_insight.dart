import 'package:fl_clash/plugins/service.dart';

/// Explains the actual Android VPN runtime without changing its configuration.
class AndroidCoreInsight {
  const AndroidCoreInsight({
    required this.engine,
    required this.status,
    required this.explanation,
    required this.suggestion,
  });

  final String engine;
  final String status;
  final String explanation;
  final String suggestion;

  static AndroidCoreInsight fromStatus(
    AndroidNativeStatus? native, {
    required bool hasProfile,
    bool refreshFailed = false,
  }) {
    if (refreshFailed) {
      return const AndroidCoreInsight(
        engine: '状态待确认',
        status: '读取失败',
        explanation: '无法获取最新内核状态，之前的显示可能已过期。',
        suggestion: '请刷新状态；不会自行重启 VPN。',
      );
    }
    if (native == null) {
      return const AndroidCoreInsight(
        engine: '正在读取',
        status: '检查中',
        explanation: '正在从 Android VPN 服务读取实际内核状态。',
        suggestion: '等待状态返回，暂不判断网络是否可用。',
      );
    }

    final standby = native.available
        ? 'sing-box 原生内核已安装，但不代表当前正在使用。'
        : '当前安装包未提供 sing-box 原生内核。';
    if (native.state == 'STARTING') {
      return AndroidCoreInsight(
        engine: '正在启动',
        status: '切换中',
        explanation: 'VPN 服务正在启动，当前出口尚不能确定。',
        suggestion: '等待启动结果，不需要重复导入或切换。$standby',
      );
    }
    if (native.state == 'STOPPING') {
      return const AndroidCoreInsight(
        engine: '正在停止',
        status: '切换中',
        explanation: 'VPN 服务正在停止，之前的连接可能已结束。',
        suggestion: '等待状态稳定，不要把这一过程当成节点不可用。',
      );
    }
    if (native.nativeOwner && native.engine != 'sing-box') {
      return const AndroidCoreInsight(
        engine: '切换待完成',
        status: '状态未稳定',
        explanation: '原生内核仍占有 VPN 运行环境，但当前没有确认 sing-box 正在运行。',
        suggestion: '先检查运行状态，不应根据旧的节点测速自动切换。',
      );
    }
    if (native.state == 'STARTED' && native.engine == 'sing-box') {
      return const AndroidCoreInsight(
        engine: 'sing-box',
        status: '已启动',
        explanation: '当前 Android VPN 由 sing-box 运行；Mihomo 不是活动内核。',
        suggestion: '内核启动不代表节点可用，实际连通性仍需网络检测。',
      );
    }
    if (native.state == 'STARTED' && native.engine == 'mihomo') {
      return AndroidCoreInsight(
        engine: 'Mihomo',
        status: '已启动',
        explanation: '当前 Android VPN 由 Mihomo 运行。$standby',
        suggestion: hasProfile
            ? '已选择订阅，可按需切换内核；实际连通性仍需网络检测。'
            : '尚未选择订阅，无法判断节点的协议兼容性。',
      );
    }
    if (native.state == 'STOPPED') {
      return AndroidCoreInsight(
        engine: '未运行',
        status: '已停止',
        explanation: 'FlClash 的 Android VPN 服务当前没有活动内核。$standby',
        suggestion: hasProfile
            ? '已有订阅，但目前没有运行中的 FlClash 内核。'
            : '尚未选择订阅，且 VPN 服务未启动。',
      );
    }
    return const AndroidCoreInsight(
      engine: '状态待确认',
      status: '尚未稳定',
      explanation: '服务状态与内核所有权尚未形成一致的运行结果。',
      suggestion: '刷新状态确认，不自动改变 DNS、节点或 VPN。',
    );
  }
}
