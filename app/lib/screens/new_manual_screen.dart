import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../theme.dart';
import 'common.dart';

/// 今あるマニュアルを貼り付けて登録する。以後の変更は差分として積む
class NewManualScreen extends StatefulWidget {
  const NewManualScreen({super.key, required this.api});
  final Api api;

  @override
  State<NewManualScreen> createState() => _NewManualScreenState();
}

class _NewManualScreenState extends State<NewManualScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  var _busy = false;

  bool get _ready => _title.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final s = await widget.api.createManual(_title.text.trim(), _body.text.trim());
      if (mounted) Navigator.pop(context, s.id);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['DiffNote（仮）', 'マニュアルを登録']),
        Expanded(
          child: PopBackground(
            child: Narrow(
              child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
                PageTitle('マニュアルを登録', emoji: '✏️', meta: [Text('以後の変更は、このマニュアルへの差分として積み上げます', style: k.text.small)]),
                SizedBox(height: k.space.xl),
                Text('何のマニュアル？', style: k.text.heading),
                SizedBox(height: k.space.sm),
                MoonTextInput(
                  controller: _title,
                  hintText: '例: キッチンマニュアル / ホールの接客',
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: k.space.xl),
                Text('今のマニュアル', style: k.text.heading),
                SizedBox(height: k.space.xs),
                Text('そのまま貼り付けてください。「## 見出し」「- 項目」の形にすると読みやすくなります。', style: k.text.small),
                SizedBox(height: k.space.sm),
                MoonTextArea(
                  controller: _body,
                  height: k.editorHeight,
                  expands: true,
                  textStyle: k.text.body,
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: k.space.xl),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MoonFilledButton(
                    onTap: _ready && !_busy ? _create : null,
                    leading: _busy ? const ButtonLoader() : null,
                    label: Text(_busy ? '登録中…' : 'この内容で登録する'),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
