import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';

/// ノートを共有する相手を足す・外す。招待や承認は無く、足すとすぐ相手のサイドバーに出る（ADR 0013）。
/// 共有された人も開ける。そのときは owner に持ち主を渡す（ADR 0016）
Future<void> showShare(BuildContext context, Api api, String manualId, {Person? owner}) => showMoonModal<void>(
  context: context,
  builder: (_) => _ShareDialog(api: api, manualId: manualId, owner: owner),
);

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.api, required this.manualId, this.owner});
  final Api api;
  final String manualId;

  /// 共有されたノートなら持ち主。自分のノートなら null
  final Person? owner;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  final _id = TextEditingController();
  List<Person>? _people;
  String? _loadError;
  var _adding = false;

  /// 外している相手の ID
  String? _removing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final people = await widget.api.shares(widget.manualId);
      if (!mounted) return;
      setState(() {
        _people = people;
        _loadError = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  Future<void> _add() async {
    final id = _id.text.trim();
    if (id.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      final people = await widget.api.share(widget.manualId, id);
      if (!mounted) return;
      setState(() {
        _people = people;
        _id.clear();
      });
      showToast(context, '$id に共有しました。相手のサイドバーに出ます');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(Person p) async {
    setState(() => _removing = p.id);
    try {
      final people = await widget.api.unshare(widget.manualId, p.id);
      if (mounted) setState(() => _people = people);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.all(k.space.lg),
      child: MoonModal(
        backgroundColor: k.colors.canvas,
        // Moon の入力欄は Material の祖先を要求する
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: k.modalWidth),
            child: Padding(
              padding: EdgeInsets.all(k.space.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('共有', style: k.text.title),
                  SizedBox(height: k.space.xs),
                  Text('共有した人も、このノートに記録・書き込み・確定ができます。ノートを消せるのは持ち主だけです', style: k.text.small),
                  if (widget.owner case final o?) ...[
                    SizedBox(height: k.space.md),
                    Text('持ち主：${o.name == o.id ? o.id : '${o.name}（${o.id}）'}', style: k.text.body),
                  ],
                  SizedBox(height: k.space.lg),
                  Text('相手のログイン ID', style: k.text.small),
                  SizedBox(height: k.space.xs),
                  MoonTextInput(
                    controller: _id,
                    hintText: '例: haruto',
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _add(),
                  ),
                  SizedBox(height: k.space.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MoonFilledButton(
                      onTap: _adding || _id.text.trim().isEmpty ? null : _add,
                      leading: _adding ? const ButtonLoader() : null,
                      label: Text(_adding ? '共有しています…' : '共有する'),
                    ),
                  ),
                  SizedBox(height: k.space.xl),
                  Text('共有している人', style: k.text.small),
                  SizedBox(height: k.space.xs),
                  _list(),
                  SizedBox(height: k.space.xl),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MoonOutlinedButton(onTap: () => Navigator.pop(context), label: const Text('閉じる')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    final k = context.tokens;
    if (_loadError case final e?) {
      return Row(
        children: [
          Expanded(child: Text(e, style: k.text.small)),
          MoonOutlinedButton(buttonSize: MoonButtonSize.sm, onTap: _load, label: const Text('もう一度読み込む')),
        ],
      );
    }
    final people = _people;
    if (people == null) return const Loading();
    if (people.isEmpty) return Text('まだ誰にも共有していません', style: k.text.body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in people)
          Row(
            children: [
              Avatar(p.name),
              SizedBox(width: k.space.sm),
              Expanded(child: Text(p.name == p.id ? p.id : '${p.name}（${p.id}）', style: k.text.body)),
              MoonTextButton(
                buttonSize: MoonButtonSize.sm,
                onTap: _removing == null ? () => _remove(p) : null,
                label: Text(_removing == p.id ? '外しています…' : '外す'),
              ),
            ],
          ),
      ],
    );
  }
}
