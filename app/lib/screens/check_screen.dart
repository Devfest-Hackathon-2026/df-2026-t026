import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';

enum _Outcome { keep, adopt, custom }

/// 食い違いの提示 → 誰に確認するか → 確定の記録 → 証拠として見せる
class CheckScreen extends StatefulWidget {
  const CheckScreen({super.key, required this.c, required this.checkId});
  final ManualController c;
  final String checkId;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  late final Check _initial = widget.c.state!.checks.firstWhere((x) => x.id == widget.checkId);
  late final _decidedBy = TextEditingController(text: _initial.candidates.firstOrNull?.who ?? '');
  late final _custom = TextEditingController(text: widget.c.state!.patch(_initial.patchId).text);
  final _note = TextEditingController();
  String _decidedAt = today();
  var _outcome = _Outcome.adopt;
  var _busy = false;

  Future<void> _resolve(Check chk, Patch p) async {
    final text = switch (_outcome) {
      _Outcome.keep => chk.conflictLine!,
      _Outcome.adopt => p.text,
      _Outcome.custom => _custom.text.trim(),
    };
    setState(() => _busy = true);
    try {
      final note = _note.text.trim();
      await widget.c.resolve(chk.id,
          decidedBy: _decidedBy.text.trim(), decidedAt: _decidedAt, text: text, note: note.isEmpty ? plain(text) : note);
      if (mounted) showToast(context, '確定しました。確認の記録に残しています');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Moon に日付選択が無いので、ここだけ Material の showDatePicker を使う（.claude/rules/flutter-ui.md）
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_decidedAt),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _decidedAt = DateFormat('yyyy-MM-dd').format(picked));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final s = widget.c.state!;
        final chk = s.checks.firstWhere((x) => x.id == widget.checkId);
        final p = s.patch(chk.patchId);
        final u = s.utterance(chk.utteranceId);
        final who = '${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）';
        return Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(title: chk.isOpen ? '確認が必要です' : '確認の記録'),
            Expanded(
              child: Narrow(
                child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xl, k.space.xl, k.space.xxl), children: [
                  if (chk.resolution != null) ...[_evidence(chk.resolution!), SizedBox(height: k.space.xxl)],
                  _step(chk.isOpen ? '1' : null, chk.isOpen ? '食い違っていること' : '食い違っていたこと'),
                  ConflictPair(
                    leftLabel: 'マニュアル',
                    left: chk.conflictLine ?? '',
                    rightLabel: who,
                    right: p.text,
                    settled: !chk.isOpen,
                  ),
                  SizedBox(height: k.space.md),
                  Text(chk.reason, style: k.text.body),
                  SizedBox(height: k.space.xs),
                  Text('元の発言：「${u.text}」', style: k.text.small),
                  if (chk.isOpen) ...[
                    SizedBox(height: k.space.xxl),
                    _step('2', '誰に確認する？'),
                    for (final cand in chk.candidates) _candidate(cand),
                    if (chk.question != null) ...[SizedBox(height: k.space.md), _question(chk.question!)],
                    SizedBox(height: k.space.xxl),
                    _step('3', '確認した結果を記録する'),
                    _form(chk, p, u),
                  ],
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }

  /// 確認は 1→2→3 の順に進むので番号を付ける。確定後は手順ではないので n を付けない
  Widget _step(String? n, String title) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: k.space.md),
      child: Row(children: [
        if (n != null) ...[
          Container(
            width: k.space.xl,
            height: k.space.xl,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.colors.ink, width: k.hairline)),
            child: Text(n, style: k.text.label),
          ),
          SizedBox(width: k.space.sm),
        ],
        Text(title, style: k.text.heading),
      ]),
    );
  }

  Widget _candidate(AskCandidate cand) {
    final k = context.tokens;
    final selected = _decidedBy.text.trim() == cand.who;
    return Padding(
      padding: EdgeInsets.only(bottom: k.space.xs),
      child: MoonMenuItem(
        backgroundColor: selected ? k.colors.sheet : null,
        borderRadius: k.radius.control,
        onTap: () => setState(() => _decidedBy.text = cand.who),
        leading: Icon(selected ? LucideIcons.circleCheck : LucideIcons.circle,
            color: selected ? k.colors.ink : k.colors.inkMuted),
        label: Text(cand.who, style: k.text.body),
        content: Text(cand.why, style: k.text.small),
      ),
    );
  }

  Widget _question(String q) {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.sm, k.space.md),
      decoration: BoxDecoration(
        color: k.colors.sheet,
        border: Border.all(color: k.colors.rule, width: k.hairline),
        borderRadius: k.radius.control,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('聞き方の例', style: k.text.small),
            SizedBox(height: k.space.xs),
            Text(q, style: k.text.body),
          ]),
        ),
        MoonButton.icon(
          semanticLabel: 'コピー',
          icon: Icon(LucideIcons.copy, color: k.colors.ink),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: q));
            if (mounted) showToast(context, 'コピーしました');
          },
        ),
      ]),
    );
  }

  Widget _form(Check chk, Patch p, Utterance u) {
    final k = context.tokens;
    final ready = _decidedBy.text.trim().isNotEmpty && (_outcome != _Outcome.custom || _custom.text.trim().isNotEmpty);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('確認した相手', style: k.text.small),
      SizedBox(height: k.space.xs),
      MoonTextInput(controller: _decidedBy, onChanged: (_) => setState(() {})),
      SizedBox(height: k.space.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: MoonOutlinedButton(
          onTap: _pickDate,
          leading: const Icon(LucideIcons.calendar),
          label: Text('${fmtDay(_decidedAt)} に確認'),
        ),
      ),
      SizedBox(height: k.space.lg),
      _option(_Outcome.keep, 'マニュアルのまま', Text(plain(chk.conflictLine ?? ''), style: k.text.small)),
      _option(_Outcome.adopt, '${u.speaker ?? '新しく聞いた方'}の言う通り', Text(plain(p.text), style: k.text.small)),
      _option(
        _Outcome.custom,
        '別の内容に決まった',
        _outcome == _Outcome.custom
            ? Padding(
                padding: EdgeInsets.only(top: k.space.xs),
                child: MoonTextInput(controller: _custom, onChanged: (_) => setState(() {})),
              )
            : null,
      ),
      SizedBox(height: k.space.lg),
      Text('メモ（何と言われたか）', style: k.text.small),
      SizedBox(height: k.space.xs),
      MoonTextInput(controller: _note, hintText: '例: 1/2で統一'),
      SizedBox(height: k.space.xl),
      Align(
        alignment: Alignment.centerRight,
        child: MoonFilledButton(
          onTap: ready && !_busy ? () => _resolve(chk, p) : null,
          leading: _busy ? const ButtonLoader() : const Icon(LucideIcons.stamp),
          label: const Text('確定する'),
        ),
      ),
    ]);
  }

  Widget _option(_Outcome value, String title, Widget? detail) {
    final k = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _outcome = value),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: k.space.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MoonRadio<_Outcome>(
            value: value,
            groupValue: _outcome,
            activeColor: k.colors.ink,
            inactiveColor: k.colors.inkMuted,
            onChanged: (v) => setState(() => _outcome = v!),
          ),
          SizedBox(width: k.space.sm),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: k.space.sm),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: k.text.body),
                ?detail,
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  /// 後で別の人に聞かれたときに見せる記録。確認印を押した形で見せる
  Widget _evidence(Resolution r) {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.all(k.space.xl),
      decoration: BoxDecoration(
        color: k.colors.sheet,
        border: Border.all(color: k.colors.rule, width: k.hairline),
        borderRadius: k.radius.surface,
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${fmtDay(r.decidedAt)} ${r.decidedBy}に確認：${r.note}', style: k.text.title),
            SizedBox(height: k.space.sm),
            Text('確定した内容：${plain(r.text)}', style: k.text.body),
          ]),
        ),
        SizedBox(width: k.space.lg),
        ConfirmStamp(who: r.decidedBy, day: r.decidedAt),
      ]),
    );
  }
}
