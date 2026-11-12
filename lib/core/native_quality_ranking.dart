import 'dart:math' as math;

/// Only actual completed measurements from the current session are eligible.
class NativeQualitySample {
  const NativeQualitySample({
    required this.tag,
    required this.state,
    required this.downloadBps,
    required this.latencyMs,
    required this.startedAt,
  });

  factory NativeQualitySample.fromMap(Map<String, dynamic> map) =>
      NativeQualitySample(
        tag: map['tag'] as String? ?? '',
        state: map['state'] as String? ?? '',
        downloadBps: (map['downloadBps'] as num?)?.toDouble() ?? 0,
        latencyMs: (map['latencyMs'] as num?)?.toDouble() ?? 0,
        startedAt: (map['startedAt'] as num?)?.toInt() ?? 0,
      );

  final String tag;
  final String state;
  final double downloadBps;
  final double latencyMs;
  final int startedAt;
}

class NativeQualityRanking {
  static const maxAge = Duration(minutes: 15);
  final Map<String, List<NativeQualitySample>> _samples = {};

  void record(NativeQualitySample sample) {
    if (sample.tag.isEmpty ||
        sample.startedAt <= 0 ||
        !const {'done', 'failed'}.contains(sample.state)) {
      return;
    }
    final samples = _samples.putIfAbsent(sample.tag, () => []);
    if (samples.any((s) => s.startedAt == sample.startedAt)) return;
    samples.add(sample);
    if (samples.length > 5) samples.removeAt(0);
  }

  void clear() => _samples.clear();

  /// Throughput is primary; penalize latency and failed recent attempts.
  /// Never recommend untested nodes or a node whose newest test failed.
  String? recommend(Iterable<String> candidates, {required int now}) {
    String? best;
    double bestScore = -1;
    for (final tag in candidates.toSet()) {
      final samples = (_samples[tag] ?? const <NativeQualitySample>[])
          .where((s) => now >= s.startedAt &&
              now - s.startedAt <= maxAge.inMilliseconds)
          .toList();
      if (samples.isEmpty || samples.last.state != 'done') continue;
      final valid = samples.where((s) => s.state == 'done' &&
          s.downloadBps.isFinite && s.downloadBps > 0).toList();
      if (valid.isEmpty) continue;
      final rates = valid.map((s) => s.downloadBps).toList()..sort();
      final middle = rates.length ~/ 2;
      final median = rates.length.isOdd
          ? rates[middle]
          : (rates[middle - 1] + rates[middle]) / 2;
      final lastLatency = valid.last.latencyMs;
      final latencyPenalty = lastLatency.isFinite && lastLatency > 0
          ? 1 + lastLatency / 500
          : 1.5;
      final reliability = valid.length / samples.length;
      final score = math.log(1 + median / 1000000) *
          reliability * reliability / latencyPenalty;
      if (score > bestScore) {
        best = tag;
        bestScore = score;
      }
    }
    return best;
  }
}
