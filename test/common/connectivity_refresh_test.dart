import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/application.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop recovery only follows a physical change or outage', () {
    const wifi = [ConnectivityResult.wifi];
    const vpnWifi = [ConnectivityResult.wifi, ConnectivityResult.vpn];
    const ethernet = [ConnectivityResult.ethernet];
    const offline = [ConnectivityResult.none];
    const vpn = [ConnectivityResult.vpn];

    expect(shouldRecoverDesktopNetwork(null, wifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, vpnWifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, wifi), isFalse);
    expect(shouldRecoverDesktopNetwork(vpnWifi, offline), isFalse);
    expect(shouldRecoverDesktopNetwork(offline, vpnWifi), isTrue);
    expect(shouldRecoverDesktopNetwork(wifi, ethernet), isTrue);
    expect(shouldRecoverDesktopNetwork(vpn, wifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, vpn), isFalse);
  });

  test('physical reconnect survives simultaneous VPN changes', () {
    const wifi = [ConnectivityResult.wifi];
    const vpnWifi = [ConnectivityResult.wifi, ConnectivityResult.vpn];
    const offline = [ConnectivityResult.none];

    expect(shouldRefreshAfterConnectivityChange(vpnWifi, offline), isTrue);
    expect(shouldRefreshAfterConnectivityChange(offline, vpnWifi), isTrue);
    expect(shouldRefreshAfterConnectivityChange(wifi, vpnWifi), isFalse);
    expect(shouldRefreshAfterConnectivityChange(vpnWifi, wifi), isFalse);
    expect(shouldRefreshAfterConnectivityChange(wifi, wifi), isTrue);
    expect(shouldRefreshAfterConnectivityChange(vpnWifi, vpnWifi), isTrue);
    expect(shouldRefreshAfterConnectivityChange(null, vpnWifi), isFalse);
    expect(shouldRefreshAfterConnectivityChange(null, wifi), isTrue);
  });
}
