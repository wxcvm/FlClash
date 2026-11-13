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
    samples.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (samples.length > 5) samples.removeAt(0);
  }

  void clear() => _samples.clear();

  /// Keep a comparison with the current node and the measured winner, then
  /// explore other members instead of permanently excluding higher-delay nodes.
  /// [ordered] is the caller's latency-ordered list of eligible proxy tags.
  List<String> candidates(
    Iterable<String> ordered, {
    required String incumbent,
    required int cursor,
    required int now,
  }) {
    final names = ordered.toSet().toList();
    if (names.isEmpty) return [];
    final chosen = <String>{
      if (names.contains(incumbent)) incumbent,
      if (recommend(names, now: now) case final String best) best,
    };
    for (var i = 0; i < names.length && chosen.length < 3; i++) {
      chosen.add(names[(cursor + i) % names.length]);
    }
    return chosen.toList();
  }

  /// Throughput is primary; penalize latency and failed recent attempts.
  /// Never recommend untested nodes or a node whose newest test failed.
  String? recommend(Iterable<String> candidates, {required int now}) {
    String? best;
    double bestScore = -1;
    for (final tag in candidates.toSet()) {
      final score = _score(tag, now);
      if (score != null && score > bestScore) {
        best = tag;
        bestScore = score;
      }
    }
    return best;
  }

  double? _score(String tag, int now) {
    final samples = (_samples[tag] ?? const <NativeQualitySample>[])
        .where(
          (s) =>
              now >= s.startedAt && now - s.startedAt <= maxAge.inMilliseconds,
        )
        .toList();
    if (samples.isEmpty || samples.last.state != 'done') return null;
    final valid = samples
        .where(
          (s) =>
              s.state == 'done' && s.downloadBps.isFinite && s.downloadBps > 0,
        )
        .toList();
    if (valid.isEmpty || valid.last != samples.last) return null;
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
    return median * reliability * reliability / latencyPenalty;
  }

  /// An explicit auto-apply batch must compare the incumbent and challenger
  /// using fresh, completed samples. No historical-only switch.
  static String? chooseAutoSwitch(
    Iterable<NativeQualitySample> completed, {
    required String incumbent,
    required int now,
  }) {
    final batch = NativeQualityRanking();
    for (final sample in completed) {
      batch.record(sample);
    }
    final current = batch._samples[incumbent]?.last;
    if (current == null ||
        now < current.startedAt ||
        now - current.startedAt > maxAge.inMilliseconds) {
      return null;
    }
    final winner = batch.recommend(batch._samples.keys, now: now);
    if (winner == null || winner == incumbent) return null;
    if (current.state == 'failed') return winner;
    final currentScore = batch._score(incumbent, now);
    final winnerScore = batch._score(winner, now);
    if (currentScore == null || winnerScore == null) return null;
    // Use the same 20% improvement margin as Mihomo automatic speed selection.
    return winnerScore >= currentScore * 1.2 ? winner : null;
  }
}
