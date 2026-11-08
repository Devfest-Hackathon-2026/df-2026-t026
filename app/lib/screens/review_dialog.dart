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

/// 発言者の候補に並べる数
const _maxSpeakers = 6;

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
  /// 書き起こしを直すと差分が作り直されるので、いつも最新の状態から引く
  Utterance get _u => widget.c.state!.utterance(widget.utteranceId);
  late final _speaker = TextEditingController(text: _u.speaker ?? '');
  late String _saidAt = _u.saidAt;
  final _editing = <String, TextEditingController>{};
  var _busy = false;

  /// 書き起こしを直している間の入力欄
  TextEditingController? _fix;

  bool get _hasSpeaker => _speaker.text.trim().isNotEmpty;

  /// 反映・確定したものは本文や確認の記録に残っているので、書き起こしは直させない
  bool _fixable(ManualState s) =>
      s.patchesOf(_u.id).every((p) => p.status != 'applied') &&
      s.checks.where((c) => c.utteranceId == _u.id).every((c) => c.resolution == null);

  /// 発言者の候補。このマニュアルで言ったことのある人を、最近の順に
  List<String> _knownSpeakers(ManualState s) {
    final recent = s.utterances.where((u) => u.id != _u.id).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return {for (final u in recent) ?u.speaker}.take(_maxSpeakers).toList();
  }

  /// 直した書き起こしで差分を作り直す。発言者と日付は、ここで変えたものだけを送り、ほかは読み直した結果に任せる
  Future<void> _fixText() async {
    final text = _fix!.text.trim();
    if (text.isEmpty) return;
    final before = _u;
    final speaker = _speaker.text.trim();
    final speakerKept = speaker == (before.speaker ?? '');
    final dayKept = _saidAt == before.saidAt;
    setState(() => _busy = true);
    try {
      await widget.c.editUtterance(
        before.id,
        text: text,
        speaker: speakerKept || speaker.isEmpty ? null : speaker,
        saidAt: dayKept ? null : _saidAt,
      );
      if (!mounted) return;
      setState(() {
        if (speakerKept) _speaker.text = _u.speaker ?? '';
        if (dayKept) _saidAt = _u.saidAt;
        _fix = null;
        _editing.clear();
      });
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('差分の確認', style: k.text.title),
                          // 入力ページからは複数のマニュアルの確認が続くので、どの1冊かを添える
                          Text(s.title, style: k.text.small),
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
                        ..._said(s),
                        SizedBox(height: k.space.lg),
                        Text('誰が言った？', style: k.text.small),
                        SizedBox(height: k.space.xs),
                        MoonTextInput(
                          controller: _speaker,
                          onChanged: (_) => setState(() {}),
                          errorText: _hasSpeaker ? null : '反映する前に入れてください',
                        ),
                        if (_knownSpeakers(s) case final known when known.isNotEmpty) ...[
                          SizedBox(height: k.space.xs),
                          Wrap(spacing: k.space.xs, runSpacing: k.space.xs, children: [
                            for (final name in known)
                              MoonChip(
                                chipSize: MoonChipSize.sm,
                                isActive: _speaker.text.trim() == name,
                                semanticLabel: '発言者を$nameにする',
                                label: Text(name),
                                onTap: () => setState(() => _speaker.text = name),
                              ),
                          ]),
                        ],
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

  /// 言われたこと（書き起こし）。聞き間違いがあれば、ここで直して差分を作り直せる
  List<Widget> _said(ManualState s) {
    final k = context.tokens;
    final fix = _fix;
    if (fix == null) {
      return [
        StickyNote(child: Text('「${_u.text}」', style: k.text.body)),
        if (_fixable(s)) ...[
          SizedBox(height: k.space.xs),
          MoonTextButton(
            onTap: _busy ? null : () => setState(() => _fix = TextEditingController(text: _u.text)),
            label: const Text('書き起こしを直す'),
          ),
        ],
      ];
    }
    return [
      MoonTextInput(controller: fix, maxLines: 4, minLines: 1, hintText: '言われたこと'),
      SizedBox(height: k.space.sm),
      Row(children: [
        MoonTextButton(onTap: _busy ? null : () => setState(() => _fix = null), label: const Text('直すのをやめる')),
        const Spacer(),
        MoonFilledButton(
          onTap: _busy ? null : _fixText,
          leading: _busy ? const ButtonLoader() : null,
          label: const Text('直して差分を作り直す'),
        ),
      ]),
    ];
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
      if (chk?.kind == Kind.contradiction)
        ..._contradiction(s, p, chk!)
      else if (chk?.kind == Kind.same)
        ..._same(p, chk!)
      else
        ..._approvable(p),
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

  // 本文は変えないのが既定。判定が外れていたときのために反映もできるようにしておく
  List<Widget> _same(Patch p, Check chk) {
    final k = context.tokens;
    return [
      Text('マニュアルの「${plain(chk.sameLine ?? '')}」と同じ内容です。本文は変えずに、言われた記録として残します', style: k.text.body),
      SizedBox(height: k.space.sm),
      if (p.status != 'proposed')
        Text(p.status == 'applied' ? '反映済み' : '記録だけ残しました', style: k.text.small)
      else
        Row(children: [
          MoonTextButton(
            onTap: _busy || !_hasSpeaker ? null : () => _run(() => widget.c.applyPatch(p.id)),
            label: const Text('それでも反映する'),
          ),
          const Spacer(),
          MoonFilledButton(
            onTap: _busy ? null : () => _run(() => widget.c.discardPatch(p.id)),
            leading: _busy ? const ButtonLoader() : null,
            label: const Text('記録だけ残す'),
          ),
        ]),
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
