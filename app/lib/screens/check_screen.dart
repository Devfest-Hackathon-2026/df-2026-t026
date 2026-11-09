import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'material_screen.dart';
import 'sidebar.dart';
import 'tab_bar.dart';

enum _Outcome { keep, adopt, custom }

/// 確認した相手の候補に並べる数（「誰が言った？」と同じ）
const _maxPeople = 6;

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

  /// 相手の資料の行が、前に資料と違う内容に確定していれば、その内容（ADR 0019）
  late final _settledOtherwise = switch (widget.c.state!.confirmedRecordFor(_initial)?.resolution) {
    final r? when _initial.materialRef != null && r.text != _initial.conflictLine => r.text,
    _ => null,
  };
  late final _custom = TextEditingController(text: _settledOtherwise ?? widget.c.state!.patch(_initial.patchId).text);
  final _note = TextEditingController();
  String _decidedAt = today();
  // 相手が確定済みの記録なら、そのまま押しても前の確定を覆さないよう「ノートのまま」から始める。
  // 資料の行が資料と違う内容に確定していたら、その内容を入れた「別の内容」から始める。
  // 相手が資料の行なら、まだ確定が無くても「資料のまま」から始める（資料は職場で決めた文書なので、口頭の側を既定にしない）
  late var _outcome = _settledOtherwise != null
      ? _Outcome.custom
      : widget.c.state!.confirmedRecordFor(_initial) != null || _initial.materialRef != null
          ? _Outcome.keep
          : _Outcome.adopt;
  var _busy = false;

  /// 「記録を見せて、ノートのままにする」を送っている間。送っている間は、どちらの確定も押せない
  var _keeping = false;

  /// 確定の入力欄を開いたか。急がせないよう、利用者が「確認できたので記録する」を押すまで閉じておく
  var _recording = false;

  /// ノートを共有している人（自分は除く）。AI の候補に無くても確認した相手に選べるようにする（ADR 0016）
  var _members = const <Person>[];

  @override
  void initState() {
    super.initState();
    // 共有された人には「誰に確認する？」を出さないので読まない（ADR 0017）
    if (widget.c.state!.sharedBy == null) _loadMembers();
  }

  /// 読めなくても、AI の候補と手入力で続ける
  Future<void> _loadMembers() async {
    final people = await widget.c.api.shares(widget.c.manualId).catchError((Object _) => const <Person>[]);
    final me = widget.c.state!.me;
    if (mounted) setState(() => _members = [for (final p in people) if (p.id != me) p]);
  }

  /// 確認した相手に選べる人（名前 → ログイン ID）。共有している人を先に、そのあとにこのノートで言ったことのある人を最近の順に。
  /// 共有していなくても、言ったことのある人から選べるようにする
  Map<String, String?> get _people {
    final s = widget.c.state!;
    final all = <String, String?>{for (final p in _members) p.name: p.id};
    final recent = [...s.utterances]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final u in recent) {
      if (s.speakerCandidate(u) case (:final name, :final id)?) all.putIfAbsent(name, () => id);
    }
    return all;
  }

  /// 確認した相手の欄の下に出す人。欄に打った言葉で、名前かログイン ID にその言葉を含む人に絞り、ID で当たった人には ID を添える。
  /// 空のときや、候補の名前がそのまま入っているときは絞らない
  List<({String name, String? id})> _shownPeople(Check chk) {
    final people = _people;
    final typed = _decidedBy.text.trim();
    final q = typed.toLowerCase();
    if (q.isEmpty || people.containsKey(typed) || chk.candidates.any((x) => x.who == typed)) {
      return [for (final name in people.keys.take(_maxPeople)) (name: name, id: null)];
    }
    return [
      for (final MapEntry(key: name, value: id) in people.entries)
        if (name.toLowerCase().contains(q)) (name: name, id: null)
        else if (id != null && id.toLowerCase().contains(q)) (name: name, id: id),
    ].take(_maxPeople).toList();
  }

  /// 2 と 3 で同じものを出す。どちらも確認した相手の欄（_decidedBy）を書き換える
  Widget _peopleChips(Check chk) {
    final k = context.tokens;
    final people = _shownPeople(chk);
    if (people.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: k.space.xs),
      child: Wrap(spacing: k.space.xs, runSpacing: k.space.xs, children: [
        for (final (:name, :id) in people)
          MoonChip(
            chipSize: MoonChipSize.sm,
            isActive: _decidedBy.text.trim() == name,
            semanticLabel: '確認した相手を$nameにする',
            label: Text(id == null ? name : '$name（$id）'),
            onTap: () => setState(() => _decidedBy.text = name),
          ),
      ]),
    );
  }

  /// 共有された人は、自分の答えとして確定する。確認した相手は送らない（ADR 0017）
  Future<void> _resolve(Check chk, Patch p, {required bool answering}) async {
    final text = switch (_outcome) {
      _Outcome.keep => chk.conflictLine!,
      _Outcome.adopt => p.text,
      _Outcome.custom => _custom.text.trim(),
    };
    setState(() => _busy = true);
    try {
      final note = _note.text.trim();
      await widget.c.resolve(chk.id,
          decidedBy: answering ? null : _decidedBy.text.trim(),
          decidedAt: answering ? today() : _decidedAt,
          text: text,
          note: note.isEmpty ? plain(text) : note);
      if (mounted) showToast(context, answering ? '確定しました。あなたが決めた記録に残しています' : '確定しました。確認の記録に残しています');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 聞き直さず、確定済みの記録を見せて済ませる。決めた人・日付・内容はサーバーが前の確定から引き継ぎ、
  /// 見せたことは押した人の行いとして残す（#118）。共有された人が押しても、その人の決定にはしない
  Future<void> _keepByRecord(Check chk, Check confirmed) async {
    setState(() => _keeping = true);
    try {
      await widget.c.resolveByRecord(chk.id, shownFrom: confirmed.id);
      if (mounted) showToast(context, '確定しました。確認の記録に残しています');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _keeping = false);
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
        final confirmed = s.confirmedRecordFor(chk);
        return PaperSheet(
          padding: EdgeInsets.all(k.space.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageTitle(
              chk.isOpen ? 'あとで確認すること' : '確認の記録',
              meta: [
                Speaker(name: u.speaker, day: u.saidAt),
                Text('元の発言：「${u.text}」', style: k.text.small),
                if (recordedByText(u) case final by?) Text(by, style: k.text.small),
              ],
            ),
            SizedBox(height: k.space.xl),
            // 後で別の人に聞かれたときに見せる記録。記録を見せて済ませた確定は、見せた人と日を上に添える（#118）
            if (chk.resolution case final r?) ...[
              ConfirmedRecord(resolution: r, shown: shownByText(s, r)),
              SizedBox(height: k.space.xxl),
            ],
            _step(chk.isOpen ? '1' : null, chk.isOpen ? '食い違っていること' : '食い違っていたこと'),
            ConflictPair(
              leftLabel: counterpartLabel(chk),
              left: chk.conflictLine ?? '',
              rightLabel: who,
              right: p.text,
              settled: !chk.isOpen,
            ),
            // 資料は書き換えないので、前後を読んで確かめられるようにする。消した資料でも出し、開いた先で消されていると出す
            if (chk.materialRef case final m?) ...[
              SizedBox(height: k.space.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonTextButton(onTap: () => _openMaterial(s, m), label: const Text('資料で前後を見る')),
              ),
            ],
            // 相手が確定済みの記録なら、その記録を証拠として比較のすぐ下に出す
            if (confirmed != null) ...[
              SizedBox(height: k.space.md),
              ConfirmedRecord(
                resolution: confirmed.resolution!,
                shown: shownByText(s, confirmed.resolution!),
                onTap: () =>
                    openCheckViaList(Navigator.of(context), widget.c, confirmed.id, settings: aboveNote(context)),
              ),
            ],
            SizedBox(height: k.space.md),
            Text(chk.reason, style: k.text.body),
            // 相手が確定済みの記録なら、聞き直さず記録を見せて済ませるのを主にし、聞き直す流れはその下に二番手として残す
            if (confirmed != null) ...[
              SizedBox(height: k.space.xl),
              _copyable('記録を見せる', _showRecord(confirmed.resolution!), '記録を見せる文をコピーする', lead: true),
              SizedBox(height: k.space.md),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonFilledButton(
                  onTap: _busy || _keeping ? null : () => _keepByRecord(chk, confirmed),
                  leading: _keeping ? const ButtonLoader() : null,
                  // 名前が長く、幅 360 ほどのスマホでは1行に収まらないので、収まらないときだけ文字を少し縮める
                  label: Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(keepByRecordLabel(s, chk, confirmed.resolution!)),
                    ),
                  ),
                ),
              ),
              SizedBox(height: k.space.xxl),
              _divider(s.sharedBy != null ? '自分で答えるなら' : 'もう一度聞くなら'),
            ],
            // 共有された人は聞かれる側なので、誰に確認するか・聞き方は出さず、すぐ答えてもらう（ADR 0017）
            if (chk.isOpen && s.sharedBy != null) ...[
              SizedBox(height: confirmed != null ? k.space.xl : k.space.xxl),
              _step('2', '答える'),
              _form(chk, p, u, answering: true),
            ] else if (chk.isOpen) ...[
              SizedBox(height: confirmed != null ? k.space.xl : k.space.xxl),
              _step('2', '誰に確認する？'),
              for (final cand in chk.candidates) _candidate(cand),
              SizedBox(height: k.space.md),
              Text('ほかの人', style: k.text.small),
              SizedBox(height: k.space.xs),
              MoonTextInput(controller: _decidedBy, hintText: '名前かログイン ID', onChanged: (_) => setState(() {})),
              _peopleChips(chk),
              if (chk.question != null) ...[
                SizedBox(height: k.space.md),
                _copyable('聞き方の例', chk.question!, '聞き方をコピーする'),
              ],
              SizedBox(height: k.space.xxl),
              _step('3', '聞いた結果を記録する'),
              if (_recording)
                _form(chk, p, u, answering: false)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: MoonOutlinedButton(
                    onTap: () => setState(() => _recording = true),
                    label: const Text('聞いた結果を記録する'),
                  ),
                ),
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

  /// 確定済みの記録を見せて済ませる所と、聞き直す流れの間の区切り。箱にせず、罫線と小さな文字で分ける
  Widget _divider(String label) {
    final k = context.tokens;
    return Row(children: [
      Text(label, style: k.text.small),
      SizedBox(width: k.space.sm),
      const Expanded(child: Rule()),
    ]);
  }

  /// 聞き方の例・記録を見せる文。そのまま相手に送れるようコピーできる。lead なら、このページの主として文を大きく出す
  Widget _copyable(String label, String text, String copyLabel, {bool lead = false}) {
    final k = context.tokens;
    return Container(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.sm, k.space.md),
      decoration: BoxDecoration(color: k.colors.shell, borderRadius: k.radius.control),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: k.text.small),
            SizedBox(height: k.space.xs),
            Text(text, style: lead ? k.text.heading : k.text.body),
          ]),
        ),
        MoonButton.icon(
          semanticLabel: copyLabel,
          icon: Icon(LucideIcons.copy, color: k.colors.ink),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (mounted) showToast(context, 'コピーしました');
          },
        ),
      ]),
    );
  }

  /// answering なら、共有された人が自分で答える欄。確認した相手と日付は無い
  Widget _form(Check chk, Patch p, Utterance u, {required bool answering}) {
    final k = context.tokens;
    final ready = (answering || _decidedBy.text.trim().isNotEmpty) && (_outcome != _Outcome.custom || _custom.text.trim().isNotEmpty);
    final keep = _choice(_Outcome.keep, _keepLabel(chk), Text(plain(chk.conflictLine ?? ''), style: k.text.heading));
    final adopt =
        _choice(_Outcome.adopt, '${u.speaker ?? '新しく聞いた方'}の言う通り', Text(plain(p.text), style: k.text.body));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!answering) ...[
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
        _peopleChips(chk),
        SizedBox(height: k.space.xl),
      ],
      Text(answering ? 'どちらにする？' : 'どちらに決まった？', style: k.text.small),
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
        answering ? '別の内容にする' : '別の内容に決まった',
        _outcome == _Outcome.custom ? MoonTextInput(controller: _custom, onChanged: (_) => setState(() {})) : null,
      ),
      SizedBox(height: k.space.xl),
      Text(answering ? 'メモ（理由など）' : 'メモ（何と言われたか）', style: k.text.small),
      SizedBox(height: k.space.xs),
      // どの項目でも読める例にする（#111）
      MoonTextInput(controller: _note, hintText: answering ? '例: こちらに統一する' : '例: 店長に聞いて、こちらに統一'),
      SizedBox(height: k.space.xl),
      Align(
        alignment: Alignment.centerRight,
        child: MoonFilledButton(
          onTap: ready && !_busy && !_keeping ? () => _resolve(chk, p, answering: answering) : null,
          leading: _busy ? const ButtonLoader() : null,
          label: Text(answering ? '答えて確定する' : '確認済みにする'),
        ),
      ),
    ]);
  }

  /// 相手の行を残す選択肢の名前
  String _keepLabel(Check chk) => chk.materialRef != null
      ? '資料のまま'
      : (counterpartGone(widget.c.state!, chk) ? '書き換える前の内容' : 'ノートのまま');

  /// 資料の中を、相手の行まで送って開く。戻る矢印で確認に戻る。パンくずは確認リストの上に積んだ形にする
  /// （広い画面では確認リストの右にこの詳細があり、狭い画面ではパンくずを出さない）
  void _openMaterial(ManualState s, MaterialRef m) {
    final above = aboveNote(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: above,
        builder: (_) => MaterialScreen(
          c: widget.c,
          materialId: m.materialId,
          lineNo: m.lineNo,
          parentCrumbs: [if (above != null) s.title, '確認リスト'],
        ),
      ),
    );
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

  /// 相手に見せる・言うための文。AI に作らせず、確定の記録から組み立てる。
  /// メモを書かずに確定すると決まった内容がメモに入るので、そのときはかっこを付けない
  String _showRecord(Resolution r) {
    final decided = plain(r.text);
    final memo = r.note.trim();
    final note = memo.isEmpty || memo == decided ? '' : '（$memo）';
    // 教える人が自分で答えて決めたものは、聞いたのでなく本人が決めたと書く（ADR 0017）
    final how = r.answeredBy == null ? 'に確認して' : 'が決めて';
    return '${fmtDay(r.decidedAt)} に${r.decidedBy}$how、「$decided」に決まっています$note。';
  }
}
