import 'package:flutter/material.dart';

import '../api.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('マニュアルを登録')),
      body: Narrow(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '何のマニュアル？', hintText: '例: キッチンマニュアル / ホールの接客'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _body,
            minLines: 10,
            maxLines: 24,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '今のマニュアルをそのまま貼り付けてください。\n## 見出し\n- 項目\nの形にすると読みやすくなります。',
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _ready && !_busy ? _create : null,
              child: Text(_busy ? '登録中…' : 'この内容で登録する'),
            ),
          ),
        ]),
      ),
    );
  }
}
