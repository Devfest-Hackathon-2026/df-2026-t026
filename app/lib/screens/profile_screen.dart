import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../web/files.dart';
import 'common.dart';
import 'sidebar.dart';

/// アイコンにできる形式（ブラウザで切り抜けるもの）
const _iconTypes = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'webp': 'image/webp'};

Future<PickedFile?> _pickWithFilePicker() async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: _iconTypes.keys.toList());
  if (files.isEmpty) return null;
  return (name: files.first.name, type: '', bytes: await files.first.xFile.readAsBytes());
}

/// 自分の名前とアイコンを変える（ADR 0010）。保存するまでは何も変わらない
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.api, this.pickImage = _pickWithFilePicker});
  final Api api;

  /// 「アイコンを選ぶ」で選ぶ。選ばずに閉じたら null。テストではファイル選択の代わりを渡す
  final Future<PickedFile?> Function() pickImage;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  IconImage? _icon;
  var _busy = false;

  /// 欄に今の名前とアイコンを入れたか。入れたあとは、保存するまで書き換えない
  var _filled = false;

  @override
  void initState() {
    super.initState();
    widget.api.store
      ..addListener(_fill)
      ..ensureLoaded();
    _fill();
  }

  @override
  void dispose() {
    widget.api.store.removeListener(_fill);
    _name.dispose();
    super.dispose();
  }

  /// 自分（store にある）が読めたら、欄に入れる
  void _fill() {
    final me = widget.api.store.me;
    if (_filled || me == null) return;
    _filled = true;
    _name.text = me.name;
    _icon = me.icon;
  }

  void _reload() {
    widget.api.store.load();
    setState(() {});
  }

  bool get _ready => _name.text.trim().isNotEmpty && !_busy;

  Future<void> _pick() async {
    final f = await widget.pickImage();
    if (f == null) return;
    final type = _iconTypes[f.name.split('.').last.toLowerCase()];
    if (type == null) {
      if (mounted) showError(context, 'アイコンにできるのは PNG・JPEG・WebP の画像です');
      return;
    }
    final icon = await squareIcon(f.bytes, type);
    if (mounted) setState(() => _icon = icon);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.api.updateMe(_name.text.trim(), _icon);
      if (mounted) showToast(context, '名前とアイコンを保存しました');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.profile,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['名前とアイコン']),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.api.store,
              builder: (context, _) {
                final store = widget.api.store;
                if (store.me case final me?) return _form(me);
                if (store.error case final e?) return LoadFailed(message: e.toString(), onRetry: _reload);
                return const Loading();
              },
            ),
          ),
        ])),
      ),
    );
  }

  Widget _form(Me me) {
    final k = context.tokens;
    return Narrow(
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        PageTitle('名前とアイコン', meta: [Text('ログイン ID：${me.id}', style: k.text.small)]),
        SizedBox(height: k.space.xl),
        Row(children: [
          Avatar(_name.text.trim(), image: _icon?.bytes, large: true),
          SizedBox(width: k.space.lg),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MoonOutlinedButton(onTap: _busy ? null : _pick, label: const Text('アイコンを選ぶ')),
            if (_icon != null) ...[
              SizedBox(height: k.space.xs),
              MoonTextButton(onTap: _busy ? null : () => setState(() => _icon = null), label: const Text('アイコンを外す')),
            ],
          ]),
        ]),
        SizedBox(height: k.space.xl),
        Text('名前', style: k.text.heading),
        SizedBox(height: k.space.sm),
        MoonTextInput(
          controller: _name,
          hintText: me.id,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _ready ? _save() : null,
        ),
        SizedBox(height: k.space.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: MoonFilledButton(
            onTap: _ready ? _save : null,
            leading: _busy ? const ButtonLoader() : null,
            label: Text(_busy ? '保存しています…' : '保存する'),
          ),
        ),
      ]),
    );
  }
}
