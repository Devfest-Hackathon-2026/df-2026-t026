import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../models.dart';
import '../theme.dart';
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

/// 「ファイルを選ぶ」「写真を撮る」（スマホだけ）のメニュー。trigger に、開閉するボタンを作らせる
class AttachMenu extends StatefulWidget {
  const AttachMenu({
    super.key,
    required this.pickFiles,
    required this.onPicked,
    required this.dropHint,
    required this.trigger,
  });

  final Future<List<PickedFile>> Function() pickFiles;
  final void Function(List<PickedFile> picked) onPicked;

  /// PC で「ファイルを選ぶ」に添える、貼り付けとドロップの案内
  final String dropHint;

  /// open はメニューを開いているか。toggle で開閉する
  final Widget Function(bool open, VoidCallback toggle) trigger;

  @override
  State<AttachMenu> createState() => _AttachMenuState();
}

class _AttachMenuState extends State<AttachMenu> {
  var _open = false;

  Future<void> _choose(Future<List<PickedFile>> Function() pick) async {
    setState(() => _open = false);
    widget.onPicked(await pick());
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return MoonDropdown(
      show: _open,
      // 上に開くと書いている文字に重なるので、下に開く
      dropdownAnchorPosition: MoonDropdownAnchorPosition.bottomLeft,
      backgroundColor: k.colors.canvas,
      borderColor: k.colors.rule,
      onTapOutside: () => setState(() => _open = false),
      // 既定では画面いっぱいまで広がるので、項目の幅に合わせる
      content: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MoonMenuItem(
          borderRadius: k.radius.control,
          onTap: () => _choose(widget.pickFiles),
          label: Text('ファイルを選ぶ', style: k.text.body),
          content: Text(onPhone ? 'PDF・画像' : 'PDF・画像。${widget.dropHint}', style: k.text.small),
        ),
        if (onPhone)
          MoonMenuItem(
            borderRadius: k.radius.control,
            onTap: () => _choose(takePhoto),
            label: Text('写真を撮る', style: k.text.body),
          ),
      ])),
      child: widget.trigger(_open, () => setState(() => _open = !_open)),
    );
  }
}
