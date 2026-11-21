export 'vpn_service_config.dart';

class VpnServiceResultError {
  VpnServiceResultError(this.message);

  String message;
}

enum VpnServiceWaitType { done, timeout, error }

class VpnServiceWaitResult {
  const VpnServiceWaitResult(this.type, {this.err});

  final VpnServiceWaitType type;
  final VpnServiceResultError? err;
}
