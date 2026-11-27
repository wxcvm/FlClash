import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo tracker(String id) {
  return TrackerInfo(
    id: id,
    start: DateTime.utc(2026, 11, 27, 10),
    metadata: const Metadata(),
    chains: const [],
    rule: '',
    rulePayload: '',
  );
}

void main() {
  group('ConnectionLog', () {
    test('tracks active, closed and failed connections', () {
      var log = ConnectionLog(10);
      log = log.open(ConnectionRecord(info: tracker('active')));

      expect(log.activeCount, 1);
      expect(log.failedCount, 0);
      expect(log.closedCount, 0);

      final closedAt = DateTime.utc(2026, 11, 27, 10, 1);
      log = log.close({'active'}, closedAt);
      log = log.open(
        ConnectionRecord(
          info: tracker('failed'),
          closedAt: closedAt,
          failure: const ConnectionFailure(
            kind: 'timeout',
            message: 'dial timed out',
          ),
        ),
      );

      expect(log.activeCount, 0);
      expect(log.failedCount, 1);
      expect(log.closedCount, 2);
      expect(log.list.map((entry) => entry.info.id), ['active', 'failed']);
    });

    test('applies final traffic before closing a connection', () {
      var log = ConnectionLog(10);
      log = log.open(ConnectionRecord(info: tracker('one')));
      log = log.updateTraffic({
        'one': (upload: 12, download: 34),
      });
      log = log.close({'one'}, DateTime.utc(2026, 11, 27, 10, 1));

      final entry = log.list.single;
      expect(entry.info.upload, 12);
      expect(entry.info.download, 34);
      expect(entry.isActive, isFalse);
    });

    test('keeps active entries and bounds closed history', () {
      var log = ConnectionLog(1);
      log = log.open(ConnectionRecord(info: tracker('active')));
      log = log.open(
        ConnectionRecord(
          info: tracker('old'),
          closedAt: DateTime.utc(2026, 11, 27, 10, 1),
          failure: const ConnectionFailure(kind: 'refused'),
        ),
      );
      log = log.open(
        ConnectionRecord(
          info: tracker('new'),
          closedAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );

      expect(log.list.map((entry) => entry.info.id), ['active', 'new']);
      expect(log.activeCount, 1);
      expect(log.failedCount, 0);
      expect(log.closedCount, 1);
    });

    test('parses the additional lifecycle fields without changing TrackerInfo', () {
      final info = tracker('failed');
      final json = Map<String, Object?>.from(info.toJson())
        ..['closedAt'] = '2026-11-27T10:01:00.000Z'
        ..['failure'] = {
          'kind': 'refused',
          'message': 'connection refused',
        };

      final entry = ConnectionRecord.fromJson(json);

      expect(entry.info.id, 'failed');
      expect(entry.closedAt, DateTime.utc(2026, 11, 27, 10, 1));
      expect(entry.failure?.kind, 'refused');
      expect(entry.failure?.message, 'connection refused');
    });
  });
}
