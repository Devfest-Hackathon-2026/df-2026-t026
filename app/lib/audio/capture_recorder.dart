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

/// 音声入力の最長。メモの吹き込みには足り、書き起こしの料金を抑えられる。バックエンドもこの長さで打ち切る
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

/// 切り出すとき、これ未満の無音をはさんだ前のかたまりは同じ会話とみなしてまとめる。
/// 言われた後に返事や聞き返しをしてから押しても、言われたことまで残すため
final _conversationGap = _ms(5000);

/// これ未満の声は物音とみなす
final _minVoice = _ms(200);

/// これより長く音が届かなければ、待ち受けが止まったとみなす（音は 20ms 程度ごとに届く）
const _stallAfter = Duration(seconds: 2);

/// 音声入力で、話し終わりとみなす無音の長さ。考えながら話す間で止まらないよう、切り出しより長くする
final _dictationEndSilence = _ms(1500);

/// 音声入力で、話し出さないまま止めるまでの長さ
final _noSpeech = _ms(8000);

/// 音声入力で、声が聞こえる前からさかのぼって送る長さ（話し始めを切らないため）
final _prerollBytes = _ms(500) * 2;

/// little-endian の 16bit PCM を標本にする
Int16List _samples(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  return Int16List(bytes.length ~/ 2)..setAll(0, [for (var i = 0; i + 1 < bytes.length; i += 2) d.getInt16(i, Endian.little)]);
}

/// RMS を 0〜1 の音量にする（-60dBFS で 0、0dBFS で 1）
double _level(double rms) => ((20 * log(max(rms, 1) / 32768) / ln10 + 60) / 60).clamp(0, 1);

/// 届いた標本を判定の単位（20ms）ごとに区切り、その RMS を渡す
class _Frames {
  _Frames(this._onFrame);
  final void Function(double rms) _onFrame;
  final _frame = Int16List(EnergyVad.frame);
  var _filled = 0;

  void add(Int16List s) {
    for (final x in s) {
      _frame[_filled++] = x;
      if (_filled < _frame.length) continue;
      _filled = 0;
      _onFrame(EnergyVad.rms(_frame, 0, _frame.length));
    }
  }
}

/// 常時待ち受け（遡り録音、ADR 0005）。直前60秒を端末のメモリだけに持ち、押したらその前の会話を WAV にする
class CaptureRecorder {
  CaptureRecorder._(this._rec, this._onStopped);

  /// マイクを使えなければ null。onStopped は、マイクが止まったときに1回だけ呼ぶ
  static Future<CaptureRecorder?> start(AudioRecorder rec, {VoidCallback? onStopped}) async {
    if (!await rec.hasPermission()) {
      await rec.dispose();
      return null;
    }
    final c = CaptureRecorder._(rec, onStopped);
    c._sub = (await rec.startStream(_pcm)).listen(c._onData, onDone: c._stopped);
    return c;
  }

  final AudioRecorder _rec;
  final VoidCallback? _onStopped;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = RingBuffer(sampleRate * keepSeconds);
  final _noise = NoiseFloor();
  late final _frames = _Frames(_onFrame);
  var _ended = false;

  /// いまの音量（0〜1）
  final level = ValueNotifier<double>(0);

  /// 受け取った標本の数（通しの位置）
  var _written = 0;

  /// 判定し終えた標本の数（通しの位置）
  var _judged = 0;
  var _lastVoice = -sampleRate * keepSeconds;
  ({int at, Completer<void> done})? _waiting;

  /// 前に切り出した所の終わり（通しの位置）。書き起こしを待たずに続けて押せるので、同じ発話をまた送らないため
  var _capturedUntil = 0;

  void _onData(Uint8List bytes) {
    final s = _samples(bytes);
    _buffer.add(s);
    _written += s.length;
    _frames.add(s);
  }

  /// 音が届き続けているかを確かめ、届いていなければ止まったとみなす。
  /// 画面が消えている間にマイクを止め、止めたことを知らせない端末があるため、画面に戻ったときに呼ぶ
  Future<void> checkAlive() async {
    final before = _written;
    await Future<void>.delayed(_stallAfter);
    if (!_ended && _written == before) _stopped();
  }

  void _stopped() {
    if (_ended) return;
    _ended = true;
    _onStopped?.call();
  }

  void _onFrame(double rms) {
    _judged += EnergyVad.frame;
    level.value = _level(rms);
    _noise.add(rms);
    if (rms >= _noise.threshold) _lastVoice = _judged;
    final w = _waiting;
    if (w != null && (_judged - _lastVoice >= _endSilence || _judged - w.at >= _maxExtend)) {
      _waiting = null;
      w.done.complete();
    }
  }

  /// 話し終わりを待ってから、押した時刻に最も近い発話と、そこから続く前の会話を WAV にする。
  /// 前に切り出した所までは含めない。新しい声が無ければ null
  Future<Uint8List?> capture() async {
    final at = _written;
    if (_judged - _lastVoice < _endSilence) {
      final done = Completer<void>();
      _waiting = (at: at, done: done);
      await done.future;
    }
    final all = _buffer.toList();
    final from = max(0, _capturedUntil - (_written - all.length));
    final samples = Int16List.sublistView(all, from);
    final pressed = at - (_written - samples.length);
    final chunks = EnergyVad(threshold: _noise.threshold).chunks(samples, gap: _gap, pad: _pad, minVoice: _minVoice);
    if (chunks.isEmpty) return null;
    // かたまりの間の無音は詰める。Speech-to-Text が無音を「はい。」などと書き起こすことがあるため
    final talk = conversation(chunks, pressed, gap: _conversationGap);
    _capturedUntil = _written - samples.length + talk.last.end;
    final out = Int16List(talk.fold(0, (n, c) => n + c.end - c.start));
    var i = 0;
    for (final c in talk) {
      out.setRange(i, i + c.end - c.start, samples, c.start);
      i += c.end - c.start;
    }
    return wav(out, sampleRate: sampleRate);
  }

  Future<void> stop() async {
    _ended = true;
    _waiting?.done.complete();
    _waiting = null;
    // 止めた時点で次のデータは届かないので、片付けの終わりは待たない
    unawaited(_sub.cancel());
    await _rec.dispose();
  }
}

/// テキスト欄の音声入力。声が聞こえてからの PCM を onPcm に流し、話し終わったら onEnd を呼ぶ。
/// 話し終わりは、話したあと無音が1.5秒続く・話し出さないまま8秒たつ・60秒に達する、のどれか
class Dictation {
  Dictation._(this._rec, this._onPcm, this._onEnd);

  /// マイクを使えなければ null
  static Future<Dictation?> start(
    AudioRecorder rec, {
    required void Function(Uint8List pcm) onPcm,
    required VoidCallback onEnd,
  }) async {
    if (!await rec.hasPermission()) {
      await rec.dispose();
      return null;
    }
    final d = Dictation._(rec, onPcm, onEnd);
    d._sub = (await rec.startStream(_pcm)).listen(d._onData);
    return d;
  }

  final AudioRecorder _rec;
  final void Function(Uint8List pcm) _onPcm;
  final VoidCallback _onEnd;
  late final StreamSubscription<Uint8List> _sub;
  late final _frames = _Frames(_onFrame);
  final _noise = NoiseFloor();

  var _count = 0;
  var _judged = 0;
  var _voiced = 0;
  var _lastVoice = 0;
  var _shouldEnd = false;
  var _ended = false;

  /// 声が聞こえるまでの直前の PCM。Speech-to-Text は無音を「はい。」などと書き起こすことがあるので、
  /// 声が聞こえるまでは送らず、聞こえたら話し始めの分もさかのぼって送る
  final _preroll = <Uint8List>[];

  /// 声が聞こえたか（物音は除く）。聞こえないまま終わったら、何も送っていない
  bool get heard => _voiced >= _minVoice;

  void _onData(Uint8List bytes) {
    final limit = sampleRate * maxDictationSeconds;
    if (_ended) return;
    final take = min(bytes.length ~/ 2, limit - _count);
    final pcm = Uint8List.sublistView(bytes, 0, take * 2);
    _count += take;
    final wasHeard = heard;
    _frames.add(_samples(pcm));
    if (heard) {
      if (!wasHeard) _preroll.forEach(_onPcm);
      _preroll.clear();
      _onPcm(pcm);
    } else {
      _preroll.add(pcm);
      while (_preroll.fold(0, (n, p) => n + p.length) - _preroll.first.length >= _prerollBytes) {
        _preroll.removeAt(0);
      }
    }
    if (_shouldEnd || _count >= limit) _end();
  }

  void _onFrame(double rms) {
    _judged += EnergyVad.frame;
    _noise.add(rms);
    if (rms >= _noise.threshold) {
      _voiced += EnergyVad.frame;
      _lastVoice = _judged;
    }
    if (heard ? _judged - _lastVoice >= _dictationEndSilence : _judged >= _noSpeech) _shouldEnd = true;
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _onEnd();
  }

  Future<void> stop() async {
    _ended = true;
    // 止めた時点で次のデータは届かないので、片付けの終わりは待たない
    unawaited(_sub.cancel());
    await _rec.dispose();
  }
}
