import 'dart:typed_data';

/// 16bit・モノラルの標本を WAV にする
Uint8List wav(Int16List samples, {required int sampleRate}) {
  final b = ByteData(44 + samples.length * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  const le = Endian.little;
  ascii(0, 'RIFF');
  b.setUint32(4, 36 + samples.length * 2, le);
  ascii(8, 'WAVEfmt ');
  b.setUint32(16, 16, le);
  b.setUint16(20, 1, le); // PCM
  b.setUint16(22, 1, le); // モノラル
  b.setUint32(24, sampleRate, le);
  b.setUint32(28, sampleRate * 2, le);
  b.setUint16(32, 2, le);
  b.setUint16(34, 16, le);
  ascii(36, 'data');
  b.setUint32(40, samples.length * 2, le);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, samples[i], le);
  }
  return b.buffer.asUint8List();
}
