import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../web/files.dart';

/// 添えられるファイルの拡張子と形式。バックエンドが受け付ける形式と揃える
const fileTypes = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'heic': 'image/heic',
};

/// バックエンドの上限（base64 で 15MB）に収まる元の大きさ
const maxAttachmentBytes = 10 * 1024 * 1024;

Future<List<PickedFile>> pickWithFilePicker() async => [
      for (final f in await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: fileTypes.keys.toList()))
        (name: f.name, type: '', bytes: await f.xFile.readAsBytes()),
    ];

/// Web でも端末の種類を返す。スマホではカメラを直接開くボタンを出す
bool get onPhone => const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

/// 受け付ける形式だけを残し、大きな画像は縮める。rejected は除いたものがあったか
Future<({List<Attachment> files, bool rejected})> toAttachments(List<PickedFile> picked) async {
  final files = <Attachment>[];
  for (final f in picked) {
    final mimeType =
        fileTypes[f.name.split('.').last.toLowerCase()] ?? (fileTypes.containsValue(f.type) ? f.type : null);
    if (mimeType == null) continue;
    final small = await shrinkImage(f.bytes, mimeType);
    files.add(Attachment(name: f.name, mimeType: small.mimeType, bytes: small.bytes));
  }
  return (files: files, rejected: files.length < picked.length);
}
