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
import 'sidebar.dart';

enum _Outcome { keep, adopt, custom }

/// 食い違い1件の画面。狭い画面で確認リストから開く。広い画面では確認リストの右に CheckDetail を直接置く
class CheckScreen extends StatelessWidget {
  const CheckScreen({super.key, required this.c, required this.checkId});
  final ManualController c;
  final String checkId;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state!;
        final chk = s.checks.firstWhere((x) => x.id == checkId);
        return Scaffold(
          body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: [s.title, '確認リスト', chk.isOpen ? 'あとで確認' : '確認の記録']),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl),
                child: Narrow(child: CheckDetail(c: c, checkId: checkId)),
              ),
            ),
          ]))),
        );
      },
    );
  }
}

/// 食い違いの提示 → 誰に確認するか → 確定の記録 → 証拠として見せる
class CheckDetail extends StatefulWidget {
  const CheckDetail({super.key, required this.c, required this.checkId});
  final ManualController c;
  final String checkId;

  @override
  State<CheckDetail> createState() => _CheckDetailState();
}

class _CheckDetailState extends State<CheckDetail> {
  late final Check _initial = widget.c.state!.checks.firstWhere((x) => x.id == widget.checkId);
  late final _decidedBy = TextEditingController(text: _initial.candidates.firstOrNull?.who ?? '');
  late final _custom = TextEditingController(text: widget.c.state!.patch(_initial.patchId).text);
  final _note = TextEditingController();
  String _decidedAt = today();
  var _outcome = _Outcome.adopt;
  var _busy = false;

  /// 確定の入力欄を開いたか。急がせないよう、利用者が「確認できたので記録する」を押すまで閉じておく
  var _recording = false;

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
        return PaperSheet(
          padding: EdgeInsets.all(k.space.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageTitle(
              chk.isOpen ? 'あとで確認すること' : '確認の記録',
              meta: [Speaker(name: u.speaker, day: u.saidAt), Text('元の発言：「${u.text}」', style: k.text.small)],
            ),
            SizedBox(height: k.space.xl),
            if (chk.resolution != null) ...[_evidence(chk.resolution!), SizedBox(height: k.space.xxl)],
            _step(chk.isOpen ? '1' : null, chk.isOpen ? '食い違っていること' : '食い違っていたこと'),
            ConflictPair(
              leftLabel: 'ノート',
              left: chk.conflictLine ?? '',
              rightLabel: who,
              right: p.text,
              settled: !chk.isOpen,
            ),
            SizedBox(height: k.space.md),
            Text(chk.reason, style: k.text.body),
            if (chk.isOpen) ...[
              SizedBox(height: k.space.xxl),
              _step('2', '誰に確認する？'),
              for (final cand in chk.candidates) _candidate(cand),
              if (chk.question != null) ...[SizedBox(height: k.space.md), _question(chk.question!)],
              SizedBox(height: k.space.xxl),
              // 確定はノートの持ち主だけがする（ADR 0013）
              if (s.sharedBy case final owner?)
                Text('聞いた結果は、ノートの持ち主の ${owner.name} が記録します', style: k.text.small)
              else ...[
                _step('3', '聞いた結果を記録する'),
                if (_recording)
                  _form(chk, p, u)
                else ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MoonOutlinedButton(
                      onTap: () => setState(() => _recording = true),
                      label: const Text('聞いた結果を記録する'),
                    ),
                  ),
                ],
              ],
            ],
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
        Text(title, style: k.text.title),
      ]),
    );
  }

  Widget _candidate(AskCandidate cand) {
    final k = context.tokens;
    final selected = _decidedBy.text.trim() == cand.who;
    return Padding(
      padding: EdgeInsets.only(bottom: k.space.xs),
      child: MoonMenuItem(
        backgroundColor: selected ? k.colors.shell : null,
        borderRadius: k.radius.control,
        onTap: () => setState(() => _decidedBy.text = cand.who),
        leading: SpeakerFace(cand.who),
        label: Text(cand.who, style: k.text.body),
        content: Text(cand.why, style: k.text.small),
        trailing: selected ? Icon(LucideIcons.check, color: k.colors.ink) : null,
      ),
    );
  }

  Widget _question(String q) {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.sm, k.space.md),
      decoration: BoxDecoration(color: k.colors.shell, borderRadius: k.radius.control),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('聞き方の例', style: k.text.small),
            SizedBox(height: k.space.xs),
            Text(q, style: k.text.body),
          ]),
        ),
        MoonButton.icon(
          semanticLabel: '聞き方をコピーする',
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
    // 相手の行が書き換えられてもうノートに無いときは、「ノートのまま」だと今のノートの行と読めてしまう（#86）
    final gone = !widget.c.state!.lines.any((l) => l.text == chk.conflictLine);
    final keep = _choice(
        _Outcome.keep, gone ? '書き換える前の内容' : 'ノートのまま', Text(plain(chk.conflictLine ?? ''), style: k.text.heading));
    final adopt =
        _choice(_Outcome.adopt, '${u.speaker ?? '新しく聞いた方'}の言う通り', Text(plain(p.text), style: k.text.body));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('確認した相手', style: k.text.small),
      SizedBox(height: k.space.xs),
      Row(children: [
        Expanded(child: MoonTextInput(controller: _decidedBy, onChanged: (_) => setState(() {}))),
        SizedBox(width: k.space.sm),
        MoonOutlinedButton(
          onTap: _pickDate,
          leading: const Icon(LucideIcons.calendar),
          label: Text('${fmtDay(_decidedAt)} に聞いた'),
        ),
      ]),
      SizedBox(height: k.space.xl),
      Text('どちらに決まった？', style: k.text.small),
      SizedBox(height: k.space.sm),
      // 選択肢は上の比較と同じ並び（左＝マニュアル、右＝言われたこと）にする
      LayoutBuilder(
        builder: (context, box) => box.maxWidth < k.stackBelow
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [keep, SizedBox(height: k.space.sm), adopt])
            : IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: keep),
                  SizedBox(width: k.space.sm),
                  Expanded(child: adopt),
                ]),
              ),
      ),
      SizedBox(height: k.space.sm),
      _choice(
        _Outcome.custom,
        '別の内容に決まった',
        _outcome == _Outcome.custom ? MoonTextInput(controller: _custom, onChanged: (_) => setState(() {})) : null,
      ),
      SizedBox(height: k.space.xl),
      Text('メモ（何と言われたか）', style: k.text.small),
      SizedBox(height: k.space.xs),
      MoonTextInput(controller: _note, hintText: '例: 1/2で統一'),
      SizedBox(height: k.space.xl),
      Align(
        alignment: Alignment.centerRight,
        child: MoonFilledButton(
          onTap: ready && !_busy ? () => _resolve(chk, p) : null,
          leading: _busy ? const ButtonLoader() : null,
          label: const Text('確認済みにする'),
        ),
      ),
    ]);
  }

  /// 結果の選択肢。選ぶと枠が濃くなる
  Widget _choice(_Outcome value, String title, Widget? detail) {
    final k = context.tokens;
    final selected = _outcome == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _outcome = value),
        child: Container(
          padding: EdgeInsets.all(k.space.md),
          decoration: BoxDecoration(
            color: k.colors.canvas,
            border: Border.all(color: selected ? k.colors.action : k.colors.rule, width: selected ? k.hairline * 2 : k.hairline),
            borderRadius: k.radius.surface,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              MoonRadio<_Outcome>(
                value: value,
                groupValue: _outcome,
                activeColor: k.colors.action,
                inactiveColor: k.colors.inkMuted,
                tapAreaSizeValue: k.space.xl,
                onChanged: (v) => setState(() => _outcome = v!),
              ),
              SizedBox(width: k.space.sm),
              Expanded(child: Text(title, style: k.text.body)),
            ]),
            if (detail != null) ...[SizedBox(height: k.space.sm), detail],
          ]),
        ),
      ),
    );
  }

  /// 後で別の人に聞かれたときに見せる記録。確認印を押した形で見せる
  Widget _evidence(Resolution r) {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.all(k.space.xl),
      decoration: BoxDecoration(color: k.colors.shell, borderRadius: k.radius.surface),
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
