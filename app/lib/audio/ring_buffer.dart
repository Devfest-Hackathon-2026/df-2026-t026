import 'dart:typed_data';

/// 決まった数の標本だけを持ち、古いものから上書きする。ディスクやネットワークには書き出さない
class RingBuffer {
  RingBuffer(int capacity) : _data = Int16List(capacity);

  final Int16List _data;
  var _next = 0;
  var _length = 0;

  int get length => _length;

  void add(Int16List samples) {
    for (final s in samples) {
      _data[_next] = s;
      _next = (_next + 1) % _data.length;
      if (_length < _data.length) _length++;
    }
  }

  /// 古い順に並べた写し
  Int16List toList() {
    final start = (_next - _length) % _data.length;
    return Int16List(_length)..setAll(0, [for (var i = 0; i < _length; i++) _data[(start + i) % _data.length]]);
  }
}
