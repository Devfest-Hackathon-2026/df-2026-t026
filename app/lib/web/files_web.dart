import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:web/web.dart' as web;

import '../models.dart';

/// これより大きい画像は縮める。スマホの写真は1枚3〜8MBあり、合わせて10MBの上限に2枚で届くため
const _shrinkAbove = 1024 * 1024;

/// 縮めたあとの長い辺。紙のメモの文字が読める大きさを残す
const _maxSide = 2000;

const _jpegQuality = 0.85;

/// ブラウザが描ける形式（HEIC は Safari 以外で描けないので、そのまま送る）
const _drawable = {'image/png', 'image/jpeg', 'image/webp'};

/// 大きな画像を JPEG に縮める。縮められない・小さくならないときは元のまま返す
Future<({Uint8List bytes, String mimeType})> shrinkImage(Uint8List bytes, String mimeType) async {
  final original = (bytes: bytes, mimeType: mimeType);
  if (bytes.length <= _shrinkAbove || !_drawable.contains(mimeType)) return original;
  try {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    final bitmap = await web.window.createImageBitmap(blob).toDart;
    final scale = min(1.0, _maxSide / max(bitmap.width, bitmap.height));
    final canvas = web.HTMLCanvasElement()
      ..width = (bitmap.width * scale).round()
      ..height = (bitmap.height * scale).round();
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    final done = Completer<web.Blob?>();
    canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', _jpegQuality.toJS);
    final small = await done.future;
    if (small == null) return original;
    final out = await _bytes(small);
    return out.length < bytes.length ? (bytes: out, mimeType: 'image/jpeg') : original;
  } catch (_) {
    return original;
  }
}

/// アイコンの一辺。大きく出しても 80px ほどなので、高精細の画面でも粗く見えない大きさにする
const _iconSide = 256;

/// 画像の真ん中を正方形に切り抜き、アイコンの大きさの JPEG にする（ADR 0010）。描けない形式は元のまま返す
Future<({Uint8List bytes, String mimeType})> squareIcon(Uint8List bytes, String mimeType) async {
  final original = (bytes: bytes, mimeType: mimeType);
  if (!_drawable.contains(mimeType)) return original;
  try {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    final bitmap = await web.window.createImageBitmap(blob).toDart;
    final side = min(bitmap.width, bitmap.height);
    final canvas = web.HTMLCanvasElement()
      ..width = _iconSide
      ..height = _iconSide;
    // 透明な所が JPEG で黒くならないよう、白を敷いてから描く
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D)
      ..fillStyle = 'white'.toJS
      ..fillRect(0, 0, _iconSide, _iconSide)
      ..drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, _iconSide, _iconSide);
    final done = Completer<web.Blob?>();
    canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', _jpegQuality.toJS);
    final out = await done.future;
    return out == null ? original : (bytes: await _bytes(out), mimeType: 'image/jpeg');
  } catch (_) {
    return original;
  }
}

/// スマホではカメラを直接開く。撮らずに閉じたら空
Future<List<PickedFile>> takePhoto() {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*'
    ..setAttribute('capture', 'environment');
  final done = Completer<List<PickedFile>>();
  input.addEventListener(
    'change',
    ((web.Event _) {
      _read(input.files).then(done.complete);
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event _) => done.complete([])).toJS);
  input.click();
  return done.future;
}

/// 画面への貼り付けとドロップでファイルを受け取る。at はドロップした位置（論理ピクセル。貼り付けは null）。
/// 戻り値で受け取るのをやめる
void Function() onFilesDropped(void Function(List<PickedFile> files, Offset? at) f) {
  final paste = ((web.ClipboardEvent e) {
    final files = e.clipboardData?.files;
    // 文字の貼り付けは入力欄に任せる
    if (files == null || files.length == 0) return;
    e.preventDefault();
    _read(files).then((files) => f(files, null));
  }).toJS;
  // 既定ではドロップしたファイルをブラウザが開いてしまうので止める
  final over = ((web.DragEvent e) => e.preventDefault()).toJS;
  final drop = ((web.DragEvent e) {
    e.preventDefault();
    final at = Offset(e.clientX.toDouble(), e.clientY.toDouble());
    _read(e.dataTransfer?.files).then((files) => f(files, at));
  }).toJS;
  web.document
    ..addEventListener('paste', paste)
    ..addEventListener('dragover', over)
    ..addEventListener('drop', drop);
  return () => web.document
    ..removeEventListener('paste', paste)
    ..removeEventListener('dragover', over)
    ..removeEventListener('drop', drop);
}

Future<List<PickedFile>> _read(web.FileList? files) async => [
      for (var i = 0; i < (files?.length ?? 0); i++)
        if (files!.item(i) case final f?) (name: f.name, type: f.type, bytes: await _bytes(f)),
    ];

Future<Uint8List> _bytes(web.Blob b) async => (await b.arrayBuffer().toDart).toDart.asUint8List();
