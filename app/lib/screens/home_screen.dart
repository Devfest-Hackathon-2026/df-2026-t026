import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
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

  Future<void> _create() async {
    final id = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => NewManualScreen(api: widget.api)));
    if (id != null) await _open(id);
  }

  Widget _createButton() => MoonFilledButton(
        label: const Text('マニュアルを登録'),
        onTap: _create,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['DiffNote（仮）']),
        Expanded(child: FutureBuilder(future: _manuals, builder: (context, snap) => _body(snap))),
      ]),
    );
  }

  Widget _body(AsyncSnapshot<List<ManualSummary>> snap) {
    if (snap.error case ApiException(status: 401, :final message)) {
      return _PasscodeForm(message: message, onSubmit: _enter);
    }
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final manuals = snap.data!;

    final k = context.tokens;
    return PopBackground(
      child: Narrow(
        maxWidth: k.pageWidth,
        child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
          PageTitle(
            'マニュアル',
            emoji: '📚',
            meta: [Text('教わったことを、言った人と日付つきでマニュアルに積み上げる', style: k.text.small)],
            trailing: manuals.isEmpty ? null : _createButton(),
          ),
          SizedBox(height: k.space.xl),
          if (manuals.isEmpty)
            _empty()
          else
            for (var i = 0; i < manuals.length; i++) ...[
              _tile(manuals[i], i),
              SizedBox(height: k.space.md),
            ],
        ]),
      ),
    );
  }

  /// マニュアル1冊分のタイル。色は順番でパステルを回す
  Widget _tile(ManualSummary m, int index) {
    final k = context.tokens;
    final c = k.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _open(m.id),
        child: Container(
          padding: EdgeInsets.all(k.space.lg),
          decoration: BoxDecoration(
            color: c.tiles[index % c.tiles.length],
            borderRadius: k.radius.tile,
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.title, style: k.text.title),
                SizedBox(height: k.space.sm),
                Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  StatusTag('記録 ${m.utteranceCount} 件', bg: c.canvas, fg: c.ink, emoji: '💬'),
                  if (m.openCount > 0)
                    StatusTag('あとで確認 ${m.openCount} 件', bg: c.pendingBg, fg: c.pending, emoji: '📌'),
                ]),
              ]),
            ),
            SizedBox(width: k.space.md),
            Container(
              padding: EdgeInsets.all(k.space.sm),
              decoration: BoxDecoration(color: c.canvas, shape: BoxShape.circle),
              child: Icon(LucideIcons.chevronRight, color: c.ink),
            ),
          ]),
        ),
      ),
    );
  }

  /// 最初の1冊を登録するまでの案内
  Widget _empty() {
    final k = context.tokens;
    return StickyNote(
      seed: 0,
      child: Column(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('📖', style: k.text.heading),
          SizedBox(width: k.space.sm),
          Text('まだマニュアルがありません', style: k.text.heading),
        ]),
        SizedBox(height: k.space.sm),
        Text(
          '今あるマニュアルを貼り付けて登録すると、\n口頭で教わったことをそこに積み上げていけます。',
          style: k.text.small,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: k.space.xl),
        _createButton(),
      ]),
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
    final k = context.tokens;
    return Narrow(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: k.space.xl, vertical: k.space.xxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.message, style: k.text.heading),
          SizedBox(height: k.space.xs),
          Text('合言葉は、このアプリを紹介した人に聞いてください', style: k.text.small),
          SizedBox(height: k.space.lg),
          MoonTextInput(
            controller: _passcode,
            autofocus: true,
            obscureText: true,
            hintText: '合言葉',
            onSubmitted: (_) => _submit(),
          ),
          SizedBox(height: k.space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: MoonFilledButton(label: const Text('入る'), onTap: _submit),
          ),
        ]),
      ),
    );
  }
}
