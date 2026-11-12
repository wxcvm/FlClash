import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/application.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop rebuilds only after physical handover or offline recovery', () {
    const wifi = [ConnectivityResult.wifi];
    const ethernet = [ConnectivityResult.ethernet];
    const vpnWifi = [ConnectivityResult.vpn, ConnectivityResult.wifi];
    const offline = [ConnectivityResult.none];
    expect(shouldRecoverDesktopNetwork(null, wifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, wifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, vpnWifi), isFalse);
    expect(shouldRecoverDesktopNetwork(wifi, offline), isFalse);
    expect(shouldRecoverDesktopNetwork(offline, wifi), isTrue);
    expect(shouldRecoverDesktopNetwork(wifi, ethernet), isTrue);
    expect(shouldRecoverDesktopNetwork(vpnWifi, offline), isFalse);
    expect(hasPhysicalConnectivity([ConnectivityResult.vpn]), isFalse);
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
