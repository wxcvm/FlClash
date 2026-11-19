import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/widgets/desktop_core_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop status does not mistake native process for network takeover', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: NativeCoreKind.singBox,
        nativeSystemProxy: false,
        nativeTunConfigured: false,
        switching: false,
        mihomoRunning: false,
        mihomoStatus: CoreStatus.disconnected,
      ),
      'sing-box · 仅进程运行',
    );
  });

  test('desktop status labels a handoff without claiming either engine', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: null,
        nativeSystemProxy: false,
        nativeTunConfigured: false,
        switching: true,
        mihomoRunning: true,
        mihomoStatus: CoreStatus.connected,
      ),
      '内核切换中',
    );
  });

  test('desktop status distinguishes Mihomo readiness and connection', () {
    String label(bool running, CoreStatus status) => desktopCoreStatusLabel(
      externalCore: null,
      nativeSystemProxy: false,
      nativeTunConfigured: false,
      switching: false,
      mihomoRunning: running,
      mihomoStatus: status,
    );
    expect(label(true, CoreStatus.connected), 'Mihomo · 控制连接正常');
    expect(label(true, CoreStatus.connecting), 'Mihomo · 控制连接中');
    expect(label(true, CoreStatus.disconnected), 'Mihomo · 控制连接异常');
    expect(label(false, CoreStatus.connected), '内核未运行');
  });

  test('desktop status distinguishes configured HTTP proxy from reachability', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: NativeCoreKind.xray,
        nativeSystemProxy: true,
        nativeTunConfigured: false,
        switching: false,
        mihomoRunning: false,
        mihomoStatus: CoreStatus.disconnected,
      ),
      'Xray-core · 系统代理已设置',
    );
  });

  test('configured TUN is not presented as verified routing', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: NativeCoreKind.singBox,
        nativeSystemProxy: false,
        nativeTunConfigured: true,
        switching: false,
        mihomoRunning: false,
        mihomoStatus: CoreStatus.disconnected,
      ),
      'sing-box · TUN 未验证',
    );
  });

  test('native proxy left after a crash cannot look like a healthy Mihomo', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: null,
        nativeSystemProxy: true,
        nativeTunConfigured: false,
        switching: false,
        mihomoRunning: true,
        mihomoStatus: CoreStatus.connected,
      ),
      '内核已退出 · 代理待恢复',
    );
  });
}
