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
    // 狭い画面では表の列をやめ、記録数と状態を名前の下に並べる
    final table = MediaQuery.sizeOf(context).width >= k.wideLayout;
    return Container(
      color: k.colors.canvas,
      child: Narrow(
        maxWidth: k.pageWidth,
        child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
          PageTitle(
            'マニュアル',
            meta: [Text('教わったことを、言った人と日付つきでマニュアルに積み上げる', style: k.text.small)],
            trailing: manuals.isEmpty ? null : _createButton(),
          ),
          SizedBox(height: k.space.xl),
          if (manuals.isEmpty) _empty() else ...[
            if (table) _headerRow(),
            const Rule(),
            for (final m in manuals) ...[_row(m, table: table), const Rule()],
          ],
        ]),
      ),
    );
  }

  Widget _headerRow() {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.sm),
      child: Row(children: [
        Expanded(child: Text('名前', style: k.text.small)),
        SizedBox(width: k.numberColumn, child: Text('記録', style: k.text.small)),
        SizedBox(width: k.numberColumn, child: Text('状態', style: k.text.small)),
        SizedBox(width: k.gutter),
      ]),
    );
  }

  Widget _row(ManualSummary m, {required bool table}) {
    final k = context.tokens;
    final status = m.openCount > 0
        ? StatusTag('あとで確認 ${m.openCount} 件', bg: k.colors.pendingBg, fg: k.colors.pending)
        : Text('なし', style: k.text.small);
    return MoonMenuItem(
      onTap: () => _open(m.id),
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
      horizontalGap: 0,
      label: table
          ? Row(children: [
              Expanded(child: Text(m.title, style: k.text.heading)),
              SizedBox(width: k.numberColumn, child: Text('${m.utteranceCount} 件', style: k.text.body)),
              SizedBox(width: k.numberColumn, child: Align(alignment: Alignment.centerLeft, child: status)),
            ])
          : Text(m.title, style: k.text.heading),
      content: table
          ? null
          : Padding(
              padding: EdgeInsets.only(top: k.space.xs),
              child: Wrap(spacing: k.space.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('記録 ${m.utteranceCount} 件', style: k.text.small),
                if (m.openCount > 0) status,
              ]),
            ),
      trailing: SizedBox(width: k.gutter, child: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted)),
    );
  }

  /// 最初の1冊を登録するまでの案内
  Widget _empty() {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.all(k.space.xxl),
      decoration: BoxDecoration(
        color: k.colors.shell,
        borderRadius: k.radius.surface,
      ),
      child: Column(children: [
        Text('まだマニュアルがありません', style: k.text.heading),
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
