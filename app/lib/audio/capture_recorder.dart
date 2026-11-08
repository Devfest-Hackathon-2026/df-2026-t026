import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'ring_buffer.dart';
import 'vad.dart';
import 'wav.dart';

const sampleRate = 16000;

/// 常時待ち受けで手元に持つ長さ
const keepSeconds = 60;

/// 音声入力の最長。Speech-to-Text の同期の書き起こしに渡せる長さに合わせる
const maxDictationSeconds = 60;

const _pcm = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: sampleRate,
  numChannels: 1,
  noiseSuppress: true,
);

int _ms(int ms) => sampleRate * ms ~/ 1000;

/// 話し終わりとみなす無音の長さ
final _endSilence = _ms(1000);

/// 押してから話し終わりを待つ最長
final _maxExtend = _ms(15000);

/// これ未満の無音は同じ発話のかたまりとする
final _gap = _ms(1500);
final _pad = _ms(300);

/// これ未満の声は物音とみなす
final _minVoice = _ms(200);

/// little-endian の 16bit PCM を標本にする
Int16List _samples(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  return Int16List(bytes.length ~/ 2)..setAll(0, [for (var i = 0; i + 1 < bytes.length; i += 2) d.getInt16(i, Endian.little)]);
}

/// RMS を 0〜1 の音量にする（-60dBFS で 0、0dBFS で 1）
double _level(double rms) => ((20 * log(max(rms, 1) / 32768) / ln10 + 60) / 60).clamp(0, 1);

/// 常時待ち受け（遡り録音、ADR 0005）。直前60秒を端末のメモリだけに持ち、押したら近くの発話だけを WAV にする
class CaptureRecorder {
  CaptureRecorder._(this._rec);

  /// マイクを使えなければ null
  static Future<CaptureRecorder?> start(AudioRecorder rec) async {
    if (!await rec.hasPermission()) {
      await rec.dispose();
      return null;
    }
    final c = CaptureRecorder._(rec);
    c._sub = (await rec.startStream(_pcm)).listen(c._onData);
    return c;
  }

  final AudioRecorder _rec;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = RingBuffer(sampleRate * keepSeconds);
  final _vad = const EnergyVad();

  /// いまの音量（0〜1）
  final level = ValueNotifier<double>(0);

  /// 判定の単位に満たない、まだ見ていない標本
  final _frame = Int16List(EnergyVad.frame);
  var _filled = 0;

  /// 受け取った標本の数（通しの位置）
  var _written = 0;
  var _lastVoice = -sampleRate * keepSeconds;
  ({int at, Completer<void> done})? _waiting;

  void _onData(Uint8List bytes) {
    final s = _samples(bytes);
    _buffer.add(s);
    for (final x in s) {
      _frame[_filled++] = x;
      _written++;
      if (_filled < _frame.length) continue;
      _filled = 0;
      final rms = EnergyVad.rms(_frame, 0, _frame.length);
      level.value = _level(rms);
      if (rms >= _vad.threshold) _lastVoice = _written;
      final w = _waiting;
      if (w != null && (_written - _lastVoice >= _endSilence || _written - w.at >= _maxExtend)) {
        _waiting = null;
        w.done.complete();
      }
    }
  }

  /// 話し終わりを待ってから、押した時刻に最も近い発話を WAV にする。声が無ければ null
  Future<Uint8List?> capture() async {
    final at = _written;
    if (_written - _lastVoice < _endSilence) {
      final done = Completer<void>();
      _waiting = (at: at, done: done);
      await done.future;
    }
    final samples = _buffer.toList();
    final pressed = at - (_written - samples.length);
    final chunks = _vad.chunks(samples, gap: _gap, pad: _pad, minVoice: _minVoice);
    if (chunks.isEmpty) return null;
    int distance(Chunk c) => pressed < c.start ? c.start - pressed : max(0, pressed - c.end);
    final nearest = chunks.reduce((a, b) => distance(b) < distance(a) ? b : a);
    return wav(Int16List.sublistView(samples, nearest.start, nearest.end), sampleRate: sampleRate);
  }

  Future<void> stop() async {
    _waiting?.done.complete();
    _waiting = null;
    // 止めた時点で次のデータは届かないので、片付けの終わりは待たない
    unawaited(_sub.cancel());
    await _rec.dispose();
  }
}

/// テキスト欄の音声入力。始めてから止めるまで（最長60秒）を WAV にする
class Dictation {
  Dictation._(this._rec, this._onFull);

  /// マイクを使えなければ null。最長に達したら onFull を呼ぶ
  static Future<Dictation?> start(AudioRecorder rec, {required VoidCallback onFull}) async {
    if (!await rec.hasPermission()) {
      await rec.dispose();
      return null;
    }
    final d = Dictation._(rec, onFull);
    d._sub = (await rec.startStream(_pcm)).listen(d._onData);
    return d;
  }

  final AudioRecorder _rec;
  final VoidCallback _onFull;
  late final StreamSubscription<Uint8List> _sub;
  final _taken = <Int16List>[];
  var _count = 0;

  /// 録音した秒数
  final seconds = ValueNotifier<int>(0);

  void _onData(Uint8List bytes) {
    final limit = sampleRate * maxDictationSeconds;
    if (_count >= limit) return;
    final s = _samples(bytes);
    final take = Int16List.sublistView(s, 0, min(s.length, limit - _count));
    _taken.add(take);
    _count += take.length;
    seconds.value = _count ~/ sampleRate;
    if (_count >= limit) _onFull();
  }

  /// 声が無ければ null
  Future<Uint8List?> stop() async {
    // 止めた時点で次のデータは届かないので、片付けの終わりは待たない
    unawaited(_sub.cancel());
    await _rec.dispose();
    final all = Int16List(_count);
    var at = 0;
    for (final s in _taken) {
      all.setAll(at, s);
      at += s.length;
    }
    if (const EnergyVad().chunks(all, gap: _gap, pad: 0, minVoice: _minVoice).isEmpty) return null;
    return wav(all, sampleRate: sampleRate);
  }
}
