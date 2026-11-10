import 'dart:math';
import 'dart:typed_data';

/// 声のかたまり。標本の位置で、end は含まない
typedef Chunk = ({int start, int end});

/// 音量（RMS）だけで声かどうかを決める簡易 VAD
class EnergyVad {
  const EnergyVad({this.threshold = 150});

  /// 判定の単位（16kHz で 20ms）
  static const frame = 320;

  /// これ以上の RMS を声とみなす（16bit で約 -47dBFS）。マイクから離れて話す人の声は -40dBFS 前後まで下がり、
  /// それを下回る所を切り落とすと、書き起こしが言い終わりの数語だけになるため
  final double threshold;

  static double rms(Int16List s, int start, int end) {
    if (end <= start) return 0;
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += s[i] * s[i];
    }
    return sqrt(sum / (end - start));
  }

  bool voiced(Int16List s, int start) => rms(s, start, min(start + frame, s.length)) >= threshold;

  /// gap 未満の無音はつないで1つのかたまりにし、前後に pad を足す。
  /// 声の合計が minVoice に満たないかたまり（物音など）は除く
  List<Chunk> chunks(Int16List s, {required int gap, required int pad, required int minVoice}) {
    final out = <Chunk>[];
    int? start;
    var end = 0;
    var voice = 0;
    void close() {
      if (start case final from? when voice >= minVoice) out.add((start: max(0, from - pad), end: min(s.length, end + pad)));
      start = null;
      voice = 0;
    }

    for (var i = 0; i < s.length; i += frame) {
      if (!voiced(s, i)) continue;
      if (start != null && i - end >= gap) close();
      start ??= i;
      end = min(i + frame, s.length);
      voice += end - i;
    }
    close();
    return out;
  }
}

/// at に最も近いかたまりから前へ、間が gap 未満で続くかたまりをまとめて返す。chunks は古い順
List<Chunk> conversation(List<Chunk> chunks, int at, {required int gap}) {
  int distance(Chunk c) => at < c.start ? c.start - at : max(0, at - c.end);
  var last = 0;
  for (var i = 1; i < chunks.length; i++) {
    if (distance(chunks[i]) < distance(chunks[last])) last = i;
  }
  var first = last;
  while (first > 0 && chunks[first].start - chunks[first - 1].end < gap) {
    first--;
  }
  return chunks.sublist(first, last + 1);
}

/// 周りの騒音の大きさを追い、声とみなす音量をその上に置く。
/// 換気扇や食洗機の音が続く厨房で、ずっと「話している」と判定しないため
class NoiseFloor {
  /// 騒音を測る長さ（20ms ごとに 10 秒ぶん）
  static const _window = 500;

  /// 測り直す間隔（0.5 秒）
  static const _every = 25;

  /// 騒音の何倍から声とみなすか（約 +10dB）
  static const _ratio = 3.0;

  final _recent = <double>[];
  var _next = 0;
  var _sinceUpdate = 0;
  var _threshold = const EnergyVad().threshold;

  /// 声とみなす RMS。静かな所では EnergyVad の既定より下げない
  double get threshold => _threshold;

  void add(double rms) {
    if (_recent.length < _window) {
      _recent.add(rms);
    } else {
      _recent[_next] = rms;
      _next = (_next + 1) % _window;
    }
    if (++_sinceUpdate < _every) return;
    _sinceUpdate = 0;
    // 話している間も言葉の切れ目で静かになるので、下から1割の大きさを騒音とみなす
    final sorted = [..._recent]..sort();
    _threshold = max(const EnergyVad().threshold, sorted[sorted.length ~/ 10] * _ratio);
  }
}
