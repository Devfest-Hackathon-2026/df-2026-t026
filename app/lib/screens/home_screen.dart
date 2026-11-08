import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';

/// 合言葉をブラウザ（shared_preferences）に覚えておくときのキー
const passcodeKey = 'passcode';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});
  final Api api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<ManualSummary>> _manuals = widget.api.listManuals();

  void _reload() => setState(() {
        _manuals = widget.api.listManuals();
      });

  Future<void> _enter(String passcode) async {
    widget.api.passcode = passcode;
    _reload();
    try {
      await _manuals;
    } catch (_) {
      return; // 違っていれば FutureBuilder がもう一度合言葉を聞く
    }
    // 次に開いたときにまた聞かなくて済むよう、ブラウザに覚えておく
    await (await SharedPreferences.getInstance()).setString(passcodeKey, passcode);
  }

  Future<void> _open(String id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: id)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DiffNote（仮）')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('マニュアルを登録'),
        onPressed: () async {
          final id = await Navigator.push<String>(
              context, MaterialPageRoute(builder: (_) => NewManualScreen(api: widget.api)));
          if (id != null) await _open(id);
        },
      ),
      body: Narrow(
        child: FutureBuilder(
          future: _manuals,
          builder: (context, snap) {
            if (snap.error case ApiException(status: 401, :final message)) {
              return _PasscodeForm(message: message, onSubmit: _enter);
            }
            if (snap.hasError) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(snap.error.toString()),
                  TextButton(onPressed: _reload, child: const Text('もう一度読み込む')),
                ]),
              );
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
              Text('教わったことを、言った人と日付つきでマニュアルに積み上げる',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
              const SizedBox(height: 12),
              for (final m in snap.data!)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.menu_book)),
                    title: Text(m.title),
                    subtitle: Text.rich(TextSpan(children: [
                      TextSpan(text: '${m.utteranceCount} 件の記録'),
                      if (m.openCount > 0)
                        TextSpan(
                          text: '・確認待ち ${m.openCount} 件',
                          style: const TextStyle(color: warnFg, fontWeight: FontWeight.bold),
                        ),
                    ])),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(m.id),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class _PasscodeForm extends StatefulWidget {
  const _PasscodeForm({required this.message, required this.onSubmit});
  final String message;
  final ValueChanged<String> onSubmit;

  @override
  State<_PasscodeForm> createState() => _PasscodeFormState();
}

class _PasscodeFormState extends State<_PasscodeForm> {
  final _passcode = TextEditingController();

  @override
  void dispose() {
    _passcode.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _passcode.text.trim();
    if (v.isNotEmpty) widget.onSubmit(v);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.message, style: text.titleMedium),
          const SizedBox(height: 4),
          Text('合言葉は、このアプリを紹介した人に聞いてください', style: text.bodySmall?.copyWith(color: Colors.black54)),
          const SizedBox(height: 16),
          TextField(
            controller: _passcode,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: '合言葉', border: OutlineInputBorder()),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _submit, child: const Text('入る')),
        ]),
      ),
    );
  }
}
