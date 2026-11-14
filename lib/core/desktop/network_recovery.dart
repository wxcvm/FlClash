import 'dart:async';

Future<void> _waitForHealth() =>
    Future<void>.delayed(const Duration(seconds: 1));

/// Use only a fresh final failure from the core's existing two-attempt probe.
/// A successful HTTP response, invalid URL or inconclusive check does not
/// justify closing otherwise healthy connections.
Future<bool> verifyDesktopNetwork({
  required Future<void> Function() check,
  required Future<Map<String, dynamic>> Function() read,
  required bool Function() isCurrent,
  required int startedAt,
  Future<void> Function()? refreshPath,
  bool Function()? mayRecover,
  Future<void> Function() wait = _waitForHealth,
}) async {
  if (!isCurrent()) return false;
  if (refreshPath != null) {
    final health = await read();
    if (!isCurrent()) return false;
    // A physical handover has already refreshed the resolver and outbounds.
    // Do not cancel its active verification on a concurrent wake event.
    if (health['source'] == 'handover' && health['state'] == 'checking') {
      return false;
    }
    await refreshPath();
    if (!isCurrent()) return false;
  }
  await check();
  // The native probe has a 25-second deadline; allow its final snapshot
  // to arrive without running an unbounded host poll.
  for (var i = 0; i < 30 && isCurrent(); i++) {
    final health = await read();
    if (!isCurrent()) return false;
    final state = health['state'];
    final checkedAt = health['checked-at'];
    if (state == 'stopped') return false;
    if (state != 'checking' && checkedAt is num && checkedAt >= startedAt) {
      // A handover already rebuilt the network. Its verification must not
      // trigger a second teardown when a wake notification overlaps it.
      return health['source'] == 'manual' &&
          (state == 'dns-failure' || state == 'route-unreachable') &&
          health['attempt'] == 2 &&
          health['confirmed-failures'] == 2 &&
          (mayRecover?.call() ?? true);
    }
    await wait();
  }
  return false;
}

/// A local IPC timeout is distinct from an unreachable remote endpoint.
/// Require two consecutive timeouts; explicit RPC errors are not proof of a hang.
Future<bool> confirmDesktopCoreTimeout({
  required Future<void> Function() ping,
  required bool Function() isCurrent,
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    if (!isCurrent()) return false;
    try {
      await ping();
      return false;
    } on TimeoutException {
      if (!isCurrent()) return false;
    }
  }
  return isCurrent();
}
