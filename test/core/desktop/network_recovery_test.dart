import 'package:fl_clash/core/desktop/network_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> health(
  String state, {
  int at = 100,
  int attempt = 2,
  int? failures,
}) => {
  'state': state,
  'checked-at': at,
  'attempt': attempt,
  'confirmed-failures': failures ?? attempt,
  'source': 'manual',
};

Future<bool> verify(List<Map<String, dynamic>> results) {
  var index = 0;
  return verifyDesktopNetwork(
    check: () async {},
    read: () async =>
        results[index < results.length ? index++ : results.length - 1],
    isCurrent: () => true,
    startedAt: 100,
    wait: () async {},
  );
}

void main() {
  test('healthy or endpoint HTTP responses preserve connections', () async {
    for (final state in [
      'reachable',
      'http-response',
      'invalid-test-url',
      'inconclusive',
    ]) {
      expect(await verify([health(state)]), isFalse);
    }
  });

  test('two failed attempts request one recovery', () async {
    for (final state in ['dns-failure', 'route-unreachable']) {
      expect(
        await verify([health('checking', attempt: 1), health(state)]),
        isTrue,
      );
    }
    expect(await verify([health('dns-failure', attempt: 1)]), isFalse);
  });

  test('inconclusive attempts do not authorize recovery', () async {
    expect(
      await verify([
        health('checking', attempt: 1, failures: 0),
        health('dns-failure', failures: 1),
      ]),
      isFalse,
    );
    expect(
      await verify([health('route-unreachable', failures: 1)]),
      isFalse,
    );
    expect(
      await verify([
        {...health('dns-failure')}..remove('confirmed-failures'),
      ]),
      isFalse,
    );
  });

  test('handover verification cannot trigger a duplicate reset', () async {
    expect(
      await verify([
        {...health('route-unreachable'), 'source': 'handover'},
      ]),
      isFalse,
    );
  });

  test('old failure cannot authorize recovery', () async {
    expect(
      await verify([health('dns-failure', at: 99), health('reachable')]),
      isFalse,
    );
    expect(await verify([health('route-unreachable', at: 99)]), isFalse);
  });

  test('new network event or stop cancels pending decision', () async {
    var active = true;
    expect(
      await verifyDesktopNetwork(
        check: () async {},
        read: () async {
          active = false;
          return health('dns-failure');
        },
        isCurrent: () => active,
        startedAt: 100,
        wait: () async {},
      ),
      isFalse,
    );
  });
}
