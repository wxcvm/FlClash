import 'iterable.dart';

// A bounded history grows only until full, then overwrites the oldest slot.
// Generations share the same buffer, as before, without shifting every item.
class _FixedBuffer<T> {
  _FixedBuffer(this.items);

  final List<T> items;
  int head = 0;

  int slot(int index) {
    RangeError.checkValidIndex(index, items);
    return (head + index) % items.length;
  }
}

class FixedList<T> {
  final int maxLength;
  final _FixedBuffer<T> _buffer;

  final int _revision;
  List<T>? _snapshot;

  FixedList(this.maxLength, {List<T>? list})
    : assert(maxLength > 0, 'FixedList without a cap grows without bound'),
      _buffer = _FixedBuffer((list ?? <T>[])..truncate(maxLength)),
      _revision = 0;

  FixedList._(this.maxLength, this._buffer, this._revision);

  int get revision => _revision;

  void add(T item) {
    final items = _buffer.items;
    if (items.length < maxLength) {
      items.add(item);
    } else {
      items[_buffer.head] = item;
      _buffer.head = (_buffer.head + 1) % maxLength;
    }
    _snapshot = null;
  }

  void clear() {
    _buffer.items.clear();
    _buffer.head = 0;
    _snapshot = null;
  }

  FixedList<T> append(T item) {
    add(item);
    return FixedList._(maxLength, _buffer, _revision + 1);
  }

  FixedList<T> replace(Map<int, T> items) {
    items.forEach((index, item) => _buffer.items[_buffer.slot(index)] = item);
    _snapshot = null;
    return FixedList._(maxLength, _buffer, _revision + 1);
  }

  List<T> get list => _snapshot ??= List.unmodifiable(
    Iterable<T>.generate(length, (index) => this[index]),
  );

  int get length => _buffer.items.length;

  T operator [](int index) => _buffer.items[_buffer.slot(index)];

  FixedList<T> copyWith() {
    return FixedList(maxLength, list: List.of(list));
  }

  @override
  bool operator ==(Object other) =>
      other is FixedList<T> &&
      identical(other._buffer, _buffer) &&
      other._revision == _revision;

  @override
  int get hashCode => Object.hash(identityHashCode(_buffer), _revision);
}

/// Restores the head that [latest] trimmed off [current] so a paused view
/// stays anchored; the result is capped at [limit] from the tail.
List<T> retainTrimmedHead<T>(
  List<T> current,
  List<T> latest,
  int limit, {
  Object Function(T item)? keyOf,
}) {
  if (current.isEmpty || latest.isEmpty) {
    return latest;
  }
  final first = latest.first;
  final index = keyOf == null
      ? current.indexWhere((item) => identical(item, first))
      : current.indexWhere((item) => keyOf(item) == keyOf(first));
  if (index == 0) {
    return latest;
  }
  final head = index > 0 ? current.sublist(0, index) : current;
  return List.unmodifiable([...head, ...latest].take(limit));
}
