import 'dart:collection';

import 'common.dart';

/// Additional lifecycle data sent by Core beside the stable TrackerInfo
/// payload. Keeping it as a wrapper avoids changing the existing generated
/// TrackerInfo model while old event consumers remain compatible.
class ConnectionFailure {
  final String kind;
  final String message;

  const ConnectionFailure({required this.kind, this.message = ''});

  factory ConnectionFailure.fromJson(Map<String, Object?> json) {
    return ConnectionFailure(
      kind: json['kind'] as String? ?? 'other',
      message: json['message'] as String? ?? '',
    );
  }
}

class ConnectionRecord {
  final TrackerInfo info;
  final DateTime? closedAt;
  final ConnectionFailure? failure;

  const ConnectionRecord({
    required this.info,
    this.closedAt,
    this.failure,
  });

  factory ConnectionRecord.fromJson(Map<String, Object?> json) {
    final rawFailure = json['failure'];
    final rawClosedAt = json['closedAt'];
    return ConnectionRecord(
      info: TrackerInfo.fromJson(json),
      closedAt: rawClosedAt is String ? DateTime.tryParse(rawClosedAt) : null,
      failure: rawFailure is Map
          ? ConnectionFailure.fromJson(Map<String, Object?>.from(rawFailure))
          : null,
    );
  }

  bool get isActive => closedAt == null;
  bool get isFailed => failure != null;

  ConnectionRecord copyWith({
    TrackerInfo? info,
    DateTime? closedAt,
    ConnectionFailure? failure,
  }) {
    return ConnectionRecord(
      info: info ?? this.info,
      closedAt: closedAt ?? this.closedAt,
      failure: failure ?? this.failure,
    );
  }
}

class _ConnectionLogEntries {
  final int closedCapacity;
  final LinkedHashMap<String, ConnectionRecord> byId = LinkedHashMap();
  final Queue<String> closedOrder = Queue<String>();
  int activeCount = 0;
  int failedCount = 0;

  _ConnectionLogEntries(this.closedCapacity)
    : assert(closedCapacity >= 0);
}

/// Bounded connection history. Entries are updated in place and each change
/// publishes a lightweight revision wrapper, avoiding a full list copy for
/// every traffic tick.
class ConnectionLog {
  final _ConnectionLogEntries _entries;
  final int revision;
  List<ConnectionRecord>? _cachedList;

  ConnectionLog(int closedCapacity)
    : _entries = _ConnectionLogEntries(closedCapacity),
      revision = 0;

  ConnectionLog._(this._entries, this.revision);

  List<ConnectionRecord> get list =>
      _cachedList ??= List.unmodifiable(_entries.byId.values);

  int get length => _entries.byId.length;
  int get activeCount => _entries.activeCount;
  int get failedCount => _entries.failedCount;
  int get closedCount => length - activeCount;

  ConnectionLog open(ConnectionRecord record) {
    final id = record.info.id;
    final existing = _entries.byId[id];
    if (existing != null) {
      final merged = existing.copyWith(
        info: record.info,
        closedAt: record.closedAt,
        failure: record.failure,
      );
      if (merged.info == existing.info &&
          merged.closedAt == existing.closedAt &&
          merged.failure == existing.failure) {
        return this;
      }
      if (existing.isActive && !merged.isActive) {
        _entries.activeCount--;
        _entries.closedOrder.addLast(id);
      }
      if (!existing.isFailed && merged.isFailed) {
        _entries.failedCount++;
      }
      _entries.byId[id] = merged;
      _trimClosed();
      return _next();
    }

    _entries.byId[id] = record;
    if (record.isActive) {
      _entries.activeCount++;
    } else {
      _entries.closedOrder.addLast(id);
    }
    if (record.isFailed) {
      _entries.failedCount++;
    }
    _trimClosed();
    return _next();
  }

  ConnectionLog updateTraffic(Map<String, RequestTraffic> traffic) {
    if (traffic.isEmpty) {
      return this;
    }
    var changed = false;
    for (final entry in traffic.entries) {
      final record = _entries.byId[entry.key];
      if (record == null) {
        continue;
      }
      final info = record.info.copyWith(
        upload: entry.value.upload,
        download: entry.value.download,
      );
      if (info == record.info) {
        continue;
      }
      _entries.byId[entry.key] = record.copyWith(info: info);
      changed = true;
    }
    return changed ? _next() : this;
  }

  ConnectionLog close(Set<String> ids, DateTime at) {
    var changed = false;
    for (final id in ids) {
      final record = _entries.byId[id];
      if (record == null || !record.isActive) {
        continue;
      }
      _entries.byId[id] = record.copyWith(closedAt: at);
      _entries.activeCount--;
      _entries.closedOrder.addLast(id);
      changed = true;
    }
    if (!changed) {
      return this;
    }
    _trimClosed();
    return _next();
  }

  ConnectionLog closeAll(DateTime at) {
    if (_entries.activeCount == 0) {
      return this;
    }
    final activeIds = _entries.byId.entries
        .where((entry) => entry.value.isActive)
        .map((entry) => entry.key)
        .toSet();
    return close(activeIds, at);
  }

  ConnectionLog _next() => ConnectionLog._(_entries, revision + 1);

  void _trimClosed() {
    while (_entries.closedOrder.length > _entries.closedCapacity) {
      final id = _entries.closedOrder.removeFirst();
      final record = _entries.byId[id];
      if (record == null || record.isActive) {
        continue;
      }
      _entries.byId.remove(id);
      if (record.isFailed) {
        _entries.failedCount--;
      }
    }
  }
}
