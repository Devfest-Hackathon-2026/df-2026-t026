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
        leading: const Icon(LucideIcons.plus),
        label: const Text('マニュアルを登録'),
        onTap: _create,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder(
        future: _manuals,
        builder: (context, snap) {
          final manuals = snap.data;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(title: 'DiffNote（仮）', trailing: manuals?.isNotEmpty ?? false ? _createButton() : null),
            Expanded(child: _body(snap)),
          ]);
        },
      ),
    );
  }

  Widget _body(AsyncSnapshot<List<ManualSummary>> snap) {
    if (snap.error case ApiException(status: 401, :final message)) {
      return _PasscodeForm(message: message, onSubmit: _enter);
    }
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final manuals = snap.data!;
    if (manuals.isEmpty) return _empty();

    final k = context.tokens;
    return Narrow(
      child: ListView(padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.xl), children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: k.space.sm),
          child: Text('教わったことを、言った人と日付つきでマニュアルに積み上げる', style: k.text.small),
        ),
        SizedBox(height: k.space.lg),
        const Rule(),
        for (final m in manuals) ...[_row(m), const Rule()],
      ]),
    );
  }

  Widget _row(ManualSummary m) {
    final k = context.tokens;
    return MoonMenuItem(
      onTap: () => _open(m.id),
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
      label: Text(m.title, style: k.text.heading),
      content: Padding(
        padding: EdgeInsets.only(top: k.space.xs),
        child: Wrap(spacing: k.space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('記録 ${m.utteranceCount} 件', style: k.text.small),
          if (m.openCount > 0)
            MoonTag(
              tagSize: MoonTagSize.xs,
              backgroundColor: k.colors.pendingBg,
              borderRadius: k.radius.control,
              label: Text('確認待ち ${m.openCount} 件', style: k.text.label.copyWith(color: k.colors.pending)),
            ),
        ]),
      ),
      trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
    );
  }

  /// 最初の1冊を登録するまでの案内
  Widget _empty() {
    final k = context.tokens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(k.space.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.notebookPen, color: k.colors.inkMuted),
          SizedBox(height: k.space.md),
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
