import 'dart:math';
import 'dart:typed_data';

/// 声のかたまり。標本の位置で、end は含まない
typedef Chunk = ({int start, int end});

/// 音量（RMS）だけで声かどうかを決める簡易 VAD
class EnergyVad {
  const EnergyVad({this.threshold = 500});

  /// 判定の単位（16kHz で 20ms）
  static const frame = 320;

  /// これ以上の RMS を声とみなす（16bit で約 -36dBFS）
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
