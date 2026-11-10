import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'review_dialog.dart';

/// 書き込む前に利用者が確かめることが残っているか。誰が言ったか読み取れなかった（サーバーは書き込まない）か、
/// まだ書き込んでいない行（照らし合わせている間にノートが変わっていて書き込まなかった行など）が残っている。
/// 入力ページは、このカードを次の結果が出ても消さない
bool needsReview(List<Recorded> records) => records.any((r) => _speakerMissing(r) || _unwritten(r).isNotEmpty);

bool _speakerMissing(Recorded r) => r.state.utterance(r.utteranceId).speaker == null;

/// まだ書き込んでいない行。食い違いは確認リストに入っているので数えない
Iterable<Patch> _unwritten(Recorded r) => r.state
    .patchesOf(r.utteranceId)
    .where((p) => p.status == 'proposed' && r.state.checkOf(p.id)?.kind != Kind.contradiction);

/// 誰が言ったか分からないときの見出し。行ごとの印は付けず、見出しで言うだけにする
const _unnamedTitle = '誰が言ったか分からないので、まだ書き込んでいません';

/// 入力ページで照らし合わせた結果。入力欄のすぐ下に出し、次の結果が出るか、閉じるまで残す（#112）。
/// 食い違いは「ノート ／ 言われたこと」で並べ、相手が確定済みの記録なら確認印と「記録を見せる」文を添え、
/// その場で記録を見せて決着できるようにする（審査員の指摘4回目）。
/// records はサーバーが書き込んだ後の状態。誰が言ったか分からない・まだ書き込んでいない行が残ったときは、
/// 確認を割り込ませず、「確かめる」を主にしてそこから開く（設計書 0021 の C2）
class RecordResultCard extends StatefulWidget {
  const RecordResultCard({
    super.key,
    required this.records,
    required this.targets,
    required this.onSettling,
    required this.onClose,
    this.onReviewed,
  });
  final List<Recorded> records;

  /// records と同じノート・発言の、今の状態。確定や「記録した結果」はこちらで行う
  final List<ReviewTarget> targets;

  /// カードで記録を見せて決着させる食い違いの id。入力ページは、これをほかの画面での確定と取り違えてカードを消さない
  final ValueChanged<String> onSettling;
  final VoidCallback onClose;

  /// 確かめることが残ったカードの「確かめる」で開いた確認を閉じたとき。入力ページは records を今の状態に合わせ直す
  final VoidCallback? onReviewed;

  @override
  State<RecordResultCard> createState() => _RecordResultCardState();
}

class _RecordResultCardState extends State<RecordResultCard> {
  /// カードで決着させた食い違いの id と、「11/10 自分が記録を見せた（11/7 店長に確認：…）」
  final _settled = <String, String>{};

  /// 記録を見せて確定している食い違いの id。送っている間は、どの確定も押せない
  String? _settling;

  /// 「確かめる」で書き込む前の確認を開いて閉じたか。閉じたあとに残った行は、利用者がまだ書き込んでいないもの
  var _reviewed = false;

  /// 照らし合わせた時点で、誰が言ったか分かっていたか。分からなかった記録は、あとでほかの画面から発言者だけを入れても、
  /// 書き込まなかったのはノートが変わったせいではない（入力ページはほかの画面でしたことをカードに映す）
  late final bool _namedAtFirst;

  @override
  void initState() {
    super.initState();
    _namedAtFirst = !widget.records.any(_speakerMissing);
  }

  ReviewTarget _target(Recorded r) => widget.targets.firstWhere((t) => t.c.manualId == r.manualId);

  /// 照らし合わせた差分と、その分類。食い違い・書き込んだ（まだの）行・同じ内容の順に並べる。
  /// 確かめて「書き込まない」にした行は出さない
  static List<(Patch, Check)> _items(Recorded r) => [
        for (final p in r.state.patchesOf(r.utteranceId))
          if (r.state.checkOf(p.id) case final chk? when !(p.status == 'discarded' && _writes(chk.kind))) (p, chk),
      ]..sort((a, b) => _order(a.$2.kind).compareTo(_order(b.$2.kind)));

  /// ノートに書き込む分類（追記・補足）
  static bool _writes(Kind k) => k == Kind.addition || k == Kind.qualification;

  static int _order(Kind k) => switch (k) {
        Kind.contradiction => 0,
        Kind.addition || Kind.qualification => 1,
        Kind.same => 2,
      };

  /// カードに出す食い違いと、その記録
  List<(Recorded, Check)> _conflicts() => [
        for (final r in widget.records)
          for (final (_, chk) in _items(r))
            if (chk.kind == Kind.contradiction) (r, chk),
      ];

  /// 食い違った相手のうち、確定済みの記録。いちばん初めのものを見出しと確認印に使う
  Resolution? _decision() => [
        for (final (r, chk) in _conflicts()) ?r.state.confirmedRecordFor(chk)?.resolution,
      ].firstOrNull;

  /// いちばん大事なことを見出しにする。確定済みの記録と食い違ったら、誰の決定と食い違ったかまで言う
  String _title(Resolution? decision) {
    if (decision != null) {
      return decision.answeredBy == null
          ? '${decision.decidedBy}に確認済みの決定と食い違っています'
          : '${decision.decidedBy}が決めたことと食い違っています';
    }
    final left = widget.records.where((r) => _unwritten(r).isNotEmpty);
    if (left.any(_speakerMissing)) return _unnamedTitle;
    // 誰が言ったか分かっているのにサーバーが書き込まなかったのは、照らし合わせている間にノートが変わっていたとき
    // （書き換える行が残っていても書き込まない）か、前の行の書き込みで当たらなくなったとき。確かめたあとは利用者の選択
    if (left.isNotEmpty) {
      return _reviewed || !_namedAtFirst ? 'まだ書き込んでいない行があります' : 'ノートが変わっていたので、まだ書き込んでいない行があります';
    }
    final items = [
      for (final r in widget.records) ..._items(r),
    ];
    final checks = [for (final (_, chk) in items) chk];
    final conflicts = checks.where((chk) => chk.kind == Kind.contradiction);
    // 相手がどれも資料の行なら、ノートでなく資料と言う（ADR 0019）
    if (conflicts.isNotEmpty) return '${conflicts.every((chk) => chk.materialRef != null) ? '資料' : 'ノート'}と食い違っています';
    // 実際に書き込めた行だけを数える
    final written = items.where((x) => x.$1.status == 'applied' && _writes(x.$2.kind)).length;
    if (written > 0) return 'ノートに $written 行書き込みました';
    if (checks.isNotEmpty) {
      return '${checks.every((chk) => chk.materialRef != null) ? '資料' : 'ノート'}と同じ内容でした（言われた記録として残しました）';
    }
    return 'ノートは変えずに、言われた記録として残しました';
  }

  /// 「確かめる」。誰が言ったか分からない・まだ書き込んでいない行が残ったときは、書き込む前の確認を開く。
  /// それ以外で食い違いがあれば、確認リストでその食い違いを選んだ形で開く（ノートの食い違っている行を押したときと同じ）。
  /// 中身がカードとほぼ同じ「記録した結果」は挟まない。無ければ「記録した結果」を開き、書き込んだ行を見せる
  Future<void> _review() async {
    if (needsReview(widget.records)) {
      await showReview(context, widget.targets);
      if (mounted) setState(() => _reviewed = true);
      widget.onReviewed?.call();
      return;
    }
    final conflicts = _conflicts();
    if (conflicts.isEmpty) {
      showReview(context, widget.targets);
      return;
    }
    final (r, chk) = conflicts.firstWhere((x) => !_settled.containsKey(x.$2.id), orElse: () => conflicts.first);
    openCheckViaList(Navigator.of(context), _target(r).c, chk.id);
  }

  /// 確認のページの「記録を見せて、ノートのままにする」と同じく、どの確定を見せたかだけを送って確認済みにする（#118）
  Future<void> _keepByRecord(Recorded r, Check chk, Check confirmed) async {
    final c = _target(r).c;
    // 確定の応答が store に入ると、入力ページは「食い違いがほかの画面で確定された」カードを外す。
    // カードで決着させたものとして外さないよう、送る前に知らせる
    widget.onSettling(chk.id);
    setState(() => _settling = chk.id);
    try {
      await c.resolveByRecord(chk.id, shownFrom: confirmed.id);
      final s = c.state!;
      final res = s.checks.firstWhere((x) => x.id == chk.id).resolution!;
      final record = '${fmtDay(res.decidedAt)} ${res.decidedBy}${res.verb}：${res.note}';
      if (!mounted) return;
      setState(() => _settled[chk.id] = switch (shownByText(s, res)) {
            final shown? => '$shown（$record）',
            null => record,
          });
      showToast(context, '確認済みにしました。確認の記録に残しています');
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _settling = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final conflicts = _conflicts();
    final open = conflicts.where((x) => !_settled.containsKey(x.$2.id));
    final review = needsReview(widget.records);
    // 記録を見せて決着できる食い違いがあれば、そのボタンを主にし、「確かめる」は二番手にする。
    // ただし確かめることが残っていれば、書き込む前の確認を開く「確かめる」を主にする
    final settleable = !review && open.any((x) => x.$1.state.confirmedRecordFor(x.$2) != null);
    final decision = _decision();
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < k.stackBelow;
        final heading = _title(decision);
        // 食い違いはこのアプリの見せ場なので、見出しを大きくする。食い違いが無ければ落ち着いた見た目のまま
        final title = Text(heading, style: conflicts.isNotEmpty ? k.text.display : k.text.title);
        final close = MoonButton.icon(
          semanticLabel: '結果を閉じる',
          icon: Icon(LucideIcons.x, color: k.colors.ink),
          onTap: widget.onClose,
        );
        // 確定済みの記録と食い違ったら、誰の決定かを大きめの確認印で見出しに添える。狭い幅では見出しの上に置く
        final stamp = decision == null
            ? null
            : SizedBox.square(
                dimension: k.stampDiameterLarge,
                child: FittedBox(
                  child: ConfirmStamp(who: decision.decidedBy, day: decision.decidedAt, decided: decision.answeredBy != null),
                ),
              );
        return PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.lg, k.space.xl),
          // まだ確認していない食い違いは黄の線で囲んで目立たせる。黄は付箋の色でもあるので面は塗らない（flutter-ui.md）。
          // 全部決着したら、あとで確認の黄をやめる
          outline: open.isNotEmpty ? k.colors.pending : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (stamp != null && stacked) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [stamp, const Spacer(), close]),
              SizedBox(height: k.space.sm),
              title,
            ] else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Padding(padding: EdgeInsets.only(top: k.space.xs), child: title)),
                if (stamp != null) ...[SizedBox(width: k.space.lg), stamp],
                SizedBox(width: k.space.sm),
                close,
              ]),
            for (final r in widget.records) ..._note(context, r, stacked: stacked),
            SizedBox(height: k.space.xl),
            Wrap(
              spacing: k.space.md,
              runSpacing: k.space.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 記録した時点では解決を求めない。確認リストに入ったことだけを伝え、中身は「確かめる」で見せる
                if (review || (open.isNotEmpty && !settleable))
                  MoonFilledButton(onTap: _review, label: const Text('確かめる'))
                else
                  MoonTextButton(onTap: _review, label: const Text('確かめる')),
                if (open.isNotEmpty) Text('確認リストに入れました', style: k.text.small),
                // 見出しで言っていなければ（食い違いの見出しのときなど）、誰が言ったか分からないことをここで言う
                if (heading != _unnamedTitle && widget.records.any(_speakerMissing))
                  Text('誰が言ったか分かりませんでした', style: k.text.small),
              ],
            ),
          ]),
        );
      },
    );
  }

  /// 1冊のノートで起きたこと。どのノートの話かを題名で示す
  List<Widget> _note(BuildContext context, Recorded r, {required bool stacked}) {
    final k = context.tokens;
    final s = r.state;
    final u = s.utterance(r.utteranceId);
    final items = _items(r);
    final mixed = _unwritten(r).isNotEmpty && items.any((x) => x.$1.status != 'proposed' && x.$2.kind != Kind.contradiction);
    return [
      SizedBox(height: k.space.lg),
      Text(s.title, style: k.text.heading),
      for (final (p, chk) in items)
        if (chk.kind == Kind.contradiction) ...[
          SizedBox(height: k.space.sm),
          ConflictPair(
            leftLabel: counterpartLabel(chk),
            left: chk.conflictLine ?? '',
            rightLabel: '${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）',
            right: p.text,
            stacked: stacked,
            settled: _settled.containsKey(chk.id),
          ),
          if (_settled[chk.id] case final line?)
            ..._settledLine(context, line)
          else if (s.confirmedRecordFor(chk) case final confirmed?)
            ..._evidence(context, r, chk, confirmed, primary: !needsReview(widget.records)),
        ] else ...[
          SizedBox(height: k.space.sm),
          // 行が折り返しても、分類のタグは1行目にそろえる
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsets.only(top: k.space.xs), child: KindTag(chk.kind)),
            SizedBox(width: k.space.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  chk.kind == Kind.same && chk.sameLine != null ? counterpartLine(chk, chk.sameLine!) : plain(p.text),
                  style: k.text.body,
                ),
                // 書き込んだ行とまだの行がまざるときだけ、どの行がまだかを示す。全部がまだなら見出しで言うだけにする
                if (p.status == 'proposed' && chk.kind != Kind.contradiction && mixed) ...[
                  SizedBox(height: k.space.xs),
                  StatusTag('まだ書き込んでいません', bg: k.colors.shell, fg: k.colors.inkMuted),
                ],
              ]),
            ),
          ]),
        ],
      if (items.isEmpty && widget.records.length > 1) ...[
        SizedBox(height: k.space.xs),
        Text('このノートは変えずに、言われた記録として残しました', style: k.text.small),
      ],
    ];
  }

  /// 食い違った相手の確定の記録と、相手に見せる文と、記録を見せて決着させるボタン。
  /// 確認印は見出しに添えたので、ここでは見せる文を主にしてコピーできるようにする。
  /// primary でなければ（「確かめる」が主のカード）、決着のボタンは枠にする
  List<Widget> _evidence(BuildContext context, Recorded r, Check chk, Check confirmed, {required bool primary}) {
    final k = context.tokens;
    final res = confirmed.resolution!;
    final show = showRecordText(res);
    final settle = _settling == null ? () => _keepByRecord(r, chk, confirmed) : null;
    final loading = _settling == chk.id;
    // 名前が長く、幅 360 ほどのスマホでは1行に収まらないので、収まらないときだけ文字を少し縮める
    final label = Flexible(
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(keepByRecordLabel(_target(r).c.state!, chk, res))),
    );
    return [
      SizedBox(height: k.space.md),
      Text('${fmtDay(res.decidedAt)} ${res.decidedBy}${res.verb}：${res.note}', style: k.text.body),
      SizedBox(height: k.space.lg),
      Text('記録を見せる', style: k.text.label),
      SizedBox(height: k.space.xs),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(show, style: k.text.title)),
        SizedBox(width: k.space.sm),
        MoonButton.icon(
          semanticLabel: '記録を見せる文をコピーする',
          icon: Icon(LucideIcons.copy, color: k.colors.ink),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: show));
            if (context.mounted) showToast(context, 'コピーしました');
          },
        ),
      ]),
      SizedBox(height: k.space.md),
      Align(
        alignment: Alignment.centerLeft,
        child: primary
            ? MoonFilledButton(onTap: settle, leading: loading ? const ButtonLoader() : null, label: label)
            : MoonOutlinedButton(
                onTap: settle,
                leading: loading
                    ? MoonCircularLoader(color: k.colors.inkMuted, circularLoaderSize: MoonCircularLoaderSize.x2s)
                    : null,
                label: label,
              ),
      ),
    ];
  }

  /// カードで決着させた食い違い。確認リストの確認済みと同じ言い方で、見せたのは誰か・元の確定は何かを出す
  List<Widget> _settledLine(BuildContext context, String line) {
    final k = context.tokens;
    return [
      SizedBox(height: k.space.md),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(top: k.space.xs),
          child: StatusTag('確認済み', bg: k.colors.addedBg, fg: k.colors.added),
        ),
        SizedBox(width: k.space.sm),
        Expanded(child: Text(line, style: k.text.body)),
      ]),
    ];
  }
}
