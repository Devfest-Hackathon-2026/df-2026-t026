import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';

// 外側を押して閉じると発言者と日付の変更が保存されないので、閉じるボタンだけで閉じる
Future<void> showReview(BuildContext context, ManualController c, String utteranceId) => showMoonModal<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ReviewDialog(c: c, utteranceId: utteranceId),
    );

/// 差分化と分類の結果を見て、発言者と日付を確かめてから反映する
class ReviewDialog extends StatefulWidget {
  const ReviewDialog({super.key, required this.c, required this.utteranceId});
  final ManualController c;
  final String utteranceId;

  @override
  State<ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<ReviewDialog> {
  late final Utterance _u = widget.c.state!.utterance(widget.utteranceId);
  late final _speaker = TextEditingController(text: _u.speaker ?? '');
  late String _saidAt = _u.saidAt;
  final _editing = <String, TextEditingController>{};
  var _busy = false;

  bool get _hasSpeaker => _speaker.text.trim().isNotEmpty;

  /// 発言者と日付の変更を先に保存する。反映や確認はこの2つが揃っている前提
  Future<void> _saveMeta() async {
    final speaker = _speaker.text.trim();
    if (speaker == (_u.speaker ?? '') && _saidAt == _u.saidAt) return;
    await widget.c.editUtterance(_u.id, speaker: speaker.isEmpty ? null : speaker, saidAt: _saidAt);
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await _saveMeta();
      await f();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 閉じる前に発言者と日付を保存する。保存に失敗しても閉じられなくならないよう、エラーを出してから閉じる
  Future<void> _close() async {
    setState(() => _busy = true);
    try {
      await _saveMeta();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) Navigator.pop(context);
  }

  // Moon に日付選択が無いので、ここだけ Material の showDatePicker を使う（.claude/rules/flutter-ui.md）
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_saidAt),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _saidAt = DateFormat('yyyy-MM-dd').format(picked));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final s = widget.c.state!;
        final patches = s.patchesOf(_u.id);
        return Padding(
          padding: EdgeInsets.all(k.space.lg),
          child: MoonModal(
            backgroundColor: k.colors.canvas,
            // Moon の入力欄は Material の祖先を要求する
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: k.modalWidth),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.sm, 0),
                    child: Row(children: [
                      Expanded(
                        child: Row(children: [
                          Text('👀', style: k.text.title),
                          SizedBox(width: k.space.sm),
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('差分の確認', style: k.text.title),
                            // 入力ページからは複数のマニュアルの確認が続くので、どの1冊かを添える
                            Text(s.title, style: k.text.small),
                          ]),
                        ]),
                      ),
                      MoonButton.icon(
                        semanticLabel: '閉じる',
                        icon: Icon(LucideIcons.x, color: k.colors.ink),
                        onTap: _busy ? null : _close,
                      ),
                    ]),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(k.space.xl, k.space.sm, k.space.xl, k.space.xl),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        StickyNote(
                          seed: (_u.speaker ?? _u.id).codeUnits.fold(0, (a, b) => a + b),
                          child: Text('「${_u.text}」', style: k.text.hand),
                        ),
                        SizedBox(height: k.space.lg),
                        Text('誰が言った？', style: k.text.small),
                        SizedBox(height: k.space.xs),
                        MoonTextInput(
                          controller: _speaker,
                          onChanged: (_) => setState(() {}),
                          errorText: _hasSpeaker ? null : '反映する前に入れてください',
                        ),
                        SizedBox(height: k.space.sm),
                        MoonOutlinedButton(
                          onTap: _pickDate,
                          leading: const Icon(LucideIcons.calendar),
                          label: Text('${fmtDay(_saidAt)} に言われた'),
                        ),
                        SizedBox(height: k.space.xl),
                        if (patches.isEmpty)
                          Text('マニュアルに関わる内容は見つかりませんでした。発言の記録だけ残しています。', style: k.text.body),
                        for (final p in patches) ...[
                          const Rule(),
                          SizedBox(height: k.space.lg),
                          _patch(s, p),
                          SizedBox(height: k.space.lg),
                        ],
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _patch(ManualState s, Patch p) {
    final k = context.tokens;
    final chk = s.checkOf(p.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        if (chk != null) ...[KindTag(chk.kind), SizedBox(width: k.space.sm)],
        Expanded(child: Text(p.summary, style: k.text.heading)),
      ]),
      if (chk != null) ...[
        SizedBox(height: k.space.xs),
        Text(chk.reason, style: k.text.small),
      ],
      SizedBox(height: k.space.md),
      if (chk?.kind == Kind.contradiction) ..._contradiction(s, p, chk!) else ..._approvable(p),
    ]);
  }

  List<Widget> _contradiction(ManualState s, Patch p, Check chk) {
    final k = context.tokens;
    return [
      ConflictPair(
        leftLabel: 'マニュアル',
        left: chk.conflictLine ?? '',
        rightLabel: '${_hasSpeaker ? _speaker.text.trim() : '発言者未入力'}（${fmtDay(_saidAt)}）',
        right: p.text,
        settled: chk.resolution != null,
      ),
      SizedBox(height: k.space.md),
      if (chk.resolution != null)
        Text('${fmtDay(chk.resolution!.decidedAt)} ${chk.resolution!.decidedBy}に確認して確定済み',
            style: k.text.body.copyWith(color: k.colors.added))
      else ...[
        // 記録した時点では解決を求めない。確認リストに入ったことだけを伝える
        Text('確認リストに入れました。聞けるときに確認して、決まったら記録します', style: k.text.body),
        SizedBox(height: k.space.md),
        Align(
          alignment: Alignment.centerLeft,
          child: MoonOutlinedButton(
            onTap: _busy
                ? null
                : () => _run(() async {
                      if (!mounted) return;
                      final nav = Navigator.of(context);
                      nav.pop();
                      await nav.push(MaterialPageRoute(builder: (_) => CheckListScreen(c: widget.c)));
                    }),
            label: const Text('確認リストを見る'),
          ),
        ),
      ],
    ];
  }

  List<Widget> _approvable(Patch p) {
    final k = context.tokens;
    final edit = _editing[p.id];
    return [
      if (edit == null)
        PatchDiff(op: p.op, line: p.line, text: p.text)
      else
        MoonTextInput(controller: edit, maxLines: 4, minLines: 1, hintText: '反映する内容を修正'),
      SizedBox(height: k.space.sm),
      if (p.status != 'proposed')
        Text(p.status == 'applied' ? '反映済み' : '反映しない', style: k.text.small)
      else
        Row(children: [
          MoonTextButton(
            onTap: _busy ? null : () => _run(() => widget.c.discardPatch(p.id)),
            label: const Text('反映しない'),
          ),
          MoonTextButton(
            onTap: () => setState(() {
              if (edit == null) {
                _editing[p.id] = TextEditingController(text: p.text);
              } else {
                _editing.remove(p.id);
              }
            }),
            label: Text(edit == null ? '修正' : '修正をやめる'),
          ),
          const Spacer(),
          MoonFilledButton(
            onTap: _busy || !_hasSpeaker ? null : () => _run(() => widget.c.applyPatch(p.id, text: edit?.text.trim())),
            leading: _busy ? const ButtonLoader() : null,
            label: const Text('承認して反映'),
          ),
        ]),
    ];
  }
}
