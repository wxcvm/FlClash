import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/widgets/desktop_core_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop status shows the active external core first', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: NativeCoreKind.singBox,
        switching: false,
        mihomoRunning: false,
        mihomoStatus: CoreStatus.disconnected,
      ),
      'sing-box · 运行中',
    );
  });

  test('desktop status labels a handoff without claiming either engine', () {
    expect(
      desktopCoreStatusLabel(
        externalCore: null,
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
      switching: false,
      mihomoRunning: running,
      mihomoStatus: status,
    );
    expect(label(true, CoreStatus.connected), 'Mihomo · 运行中');
    expect(label(true, CoreStatus.connecting), 'Mihomo · 连接中');
    expect(label(true, CoreStatus.disconnected), 'Mihomo · 连接异常');
    expect(label(false, CoreStatus.connected), '内核未运行');
  });
}
