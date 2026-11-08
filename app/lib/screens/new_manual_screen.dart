import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'sidebar.dart';

/// ノートを作る。今あるマニュアルやメモを貼り付けるか、白紙から始める。以後の変更は差分として積む
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

  bool get _ready => _title.text.trim().isNotEmpty;
  bool get _blank => _body.text.trim().isEmpty;

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final s = await widget.api.createManual(_title.text.trim(), _body.text.trim());
      // 作ったらそのまま開き、すぐ書き始められるようにする
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: s.id)));
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: WithSidebar(api: widget.api, place: Place.manuals, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['DiffNote（仮）', 'ノートを作る']),
        Expanded(
          child: Narrow(
            child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
              PageTitle('ノートを作る', meta: [Text('以後の変更は、このノートへの差分として積み上げます', style: k.text.small)]),
              SizedBox(height: k.space.xl),
              Text('何のノート？', style: k.text.heading),
              SizedBox(height: k.space.sm),
              MoonTextInput(
                controller: _title,
                hintText: '例: キッチンマニュアル / 自分用メモ / コーディング規約',
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: k.space.xl),
              Text('最初の本文', style: k.text.heading),
              SizedBox(height: k.space.xs),
              Text('今あるマニュアルやメモは、そのまま貼り付けてください。「## 見出し」「- 項目」の形にすると読みやすくなります。\n'
                  '無ければ空のままで、白紙から書き始められます。', style: k.text.small),
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
                  label: Text(_busy ? '登録中…' : (_blank ? '白紙から始める' : 'この内容で作る')),
                ),
              ),
            ]),
          ),
        ),
      ]))),
    );
  }
}
