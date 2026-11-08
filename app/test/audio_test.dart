import 'dart:async';
import 'dart:typed_data';

import 'package:diff_note/audio/capture_recorder.dart';
import 'package:diff_note/audio/ring_buffer.dart';
import 'package:diff_note/audio/vad.dart';
import 'package:diff_note/audio/wav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

/// 20ms ごとに、声（true）か無音（false）を並べた標本
Int16List _frames(List<bool> voiced) => Int16List.fromList([
      for (final v in voiced) ...List.filled(EnergyVad.frame, v ? 3000 : 0),
    ]);

/// マイクの代わり。test が流した PCM をそのまま渡す
class _FakeMic implements AudioRecorder {
  final pcm = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async => pcm.stream;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  test('騒音の閾値は、静かな所では既定のまま、騒音が続くとその上に上がる', () {
    final quiet = NoiseFloor();
    for (var i = 0; i < 100; i++) {
      quiet.add(50);
    }
    expect(quiet.threshold, const EnergyVad().threshold);

    final kitchen = NoiseFloor();
    for (var i = 0; i < 500; i++) {
      // 換気扇の音（RMS 2000）の中で、ときどき声（RMS 8000）が入る
      kitchen.add(i % 5 == 0 ? 8000 : 2000);
    }
    expect(kitchen.threshold, greaterThan(2000));
    expect(kitchen.threshold, lessThan(8000));
  });

  testWidgets('待ち受けは、確かめたときに音が届いていなければ止まったと知らせる', (tester) async {
    var stopped = 0;
    final mic = _FakeMic();
    final c = (await CaptureRecorder.start(mic, onStopped: () => stopped++))!;

    final alive = c.checkAlive();
    mic.pcm.add(Uint8List(640));
    await tester.pump(const Duration(seconds: 3));
    await alive;
    expect(stopped, 0);

    final dead = c.checkAlive();
    await tester.pump(const Duration(seconds: 3));
    await dead;
    expect(stopped, 1);
    await c.stop();
  });
}
