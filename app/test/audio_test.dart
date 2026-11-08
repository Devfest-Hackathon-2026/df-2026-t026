import 'dart:typed_data';

import 'package:diff_note/audio/ring_buffer.dart';
import 'package:diff_note/audio/vad.dart';
import 'package:diff_note/audio/wav.dart';
import 'package:flutter_test/flutter_test.dart';

/// 20ms ごとに、声（true）か無音（false）を並べた標本
Int16List _frames(List<bool> voiced) => Int16List.fromList([
      for (final v in voiced) ...List.filled(EnergyVad.frame, v ? 3000 : 0),
    ]);

void main() {
  test('リングバッファは容量を超えたら古いものから上書きし、古い順に返す', () {
    final b = RingBuffer(4)..add(Int16List.fromList([1, 2, 3]));
    expect(b.toList(), [1, 2, 3]);
    b.add(Int16List.fromList([4, 5, 6]));
    expect(b.length, 4);
    expect(b.toList(), [3, 4, 5, 6]);
  });

  test('VAD は短い無音をつなぎ、長い無音で区切り、前後に余白を足す', () {
    const f = EnergyVad.frame;
    final s = _frames([false, false, true, true, false, true, false, false, false, false, true, true, false]);
    final chunks = const EnergyVad().chunks(s, gap: 2 * f, pad: f ~/ 2, minVoice: f);
    expect(chunks, [
      (start: 2 * f - f ~/ 2, end: 6 * f + f ~/ 2),
      (start: 10 * f - f ~/ 2, end: 12 * f + f ~/ 2),
    ]);
  });

  test('VAD は物音のような短い声を除く', () {
    const f = EnergyVad.frame;
    final s = _frames([false, true, false, false, false]);
    expect(const EnergyVad().chunks(s, gap: f, pad: 0, minVoice: 2 * f), isEmpty);
  });

  test('WAV は 16bit・モノラルのヘッダーを付ける', () {
    final w = wav(Int16List.fromList([1, -1]), sampleRate: 16000);
    final d = ByteData.sublistView(w);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 16)), 'WAVEfmt ');
    expect(d.getUint32(24, Endian.little), 16000);
    expect(d.getUint32(40, Endian.little), 4);
    expect(d.getInt16(46, Endian.little), -1);
  });
}
