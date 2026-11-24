import 'package:fl_clash/core/android_core_insight.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AndroidNativeStatus status({
    required String engine,
    required String state,
    bool available = true,
    bool nativeOwner = false,
  }) => AndroidNativeStatus(
    available: available,
    engine: engine,
    state: state,
    nativeOwner: nativeOwner,
  );

  test('availability is not mistaken for an active sing-box runtime', () {
    final insight = AndroidCoreInsight.fromStatus(
      status(engine: 'mihomo', state: 'STARTED'),
      hasProfile: true,
    );
    expect(insight.engine, 'Mihomo');
    expect(insight.status, '已启动');
    expect(insight.explanation, contains('已安装'));
    expect(insight.suggestion, contains('按需切换内核'));
    expect(insight.suggestion, isNot(contains('Karing')));
  });

  test('native engine reports startup without claiming connectivity', () {
    final insight = AndroidCoreInsight.fromStatus(
      status(engine: 'sing-box', state: 'STARTED', nativeOwner: true),
      hasProfile: true,
    );
    expect(insight.engine, 'sing-box');
    expect(insight.suggestion, contains('不代表节点可用'));
  });

  test('stopped VPN is not reported as a running default core', () {
    final insight = AndroidCoreInsight.fromStatus(
      status(engine: 'idle', state: 'STOPPED'),
      hasProfile: false,
    );
    expect(insight.engine, '未运行');
    expect(insight.status, '已停止');
    expect(insight.suggestion, contains('尚未选择订阅'));
  });

  test('unsettled ownership is shown as a transition', () {
    final insight = AndroidCoreInsight.fromStatus(
      status(engine: 'idle', state: 'STOPPED', nativeOwner: true),
      hasProfile: true,
    );
    expect(insight.status, '状态未稳定');
  });

  test('startup and stale status are explicit', () {
    final starting = AndroidCoreInsight.fromStatus(
      status(engine: 'idle', state: 'STARTING'),
      hasProfile: true,
    );
    expect(starting.status, '切换中');
    final failed = AndroidCoreInsight.fromStatus(
      status(engine: 'mihomo', state: 'STARTED'),
      hasProfile: true,
      refreshFailed: true,
    );
    expect(failed.status, '读取失败');
  });
}
