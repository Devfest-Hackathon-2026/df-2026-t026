import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../models.dart';
import '../theme.dart';
import 'common.dart';

/// 入力ページで、確認を開かずに書き込んだ結果。入力欄のすぐ下に出し、次に記録するか、閉じるまで残す（#112）。
/// 食い違いは「ノート ／ 言われたこと」で並べ、相手が確定済みの記録なら確認印と「記録を見せる」文を添える。
/// records は照らし合わせた直後（書き込む前）の状態。書き込むたびに状態が置き換わるので、分類はこちらから読む
class RecordResultCard extends StatelessWidget {
  const RecordResultCard({super.key, required this.records, required this.onReview, required this.onClose});
  final List<Recorded> records;

  /// 「確かめる」。記録した結果（書き込む前の確認と同じダイアログ）を開く
  final VoidCallback onReview;
  final VoidCallback onClose;

  /// 照らし合わせた差分と、その分類。食い違い・書き込んだ行・同じ内容の順に並べる
  static List<(Patch, Check)> _items(Recorded r) => [
        for (final p in r.state.patchesOf(r.utteranceId))
          if (r.state.checkOf(p.id) case final chk? when p.status == 'proposed') (p, chk),
      ]..sort((a, b) => _order(a.$2.kind).compareTo(_order(b.$2.kind)));

  static int _order(Kind k) => switch (k) {
        Kind.contradiction => 0,
        Kind.addition || Kind.qualification => 1,
        Kind.same => 2,
      };

  /// 食い違った相手のうち、確定済みの記録。いちばん初めのものを見出しと確認印に使う
  Resolution? _settled() => [
        for (final r in records)
          for (final (_, chk) in _items(r))
            if (chk.kind == Kind.contradiction) ?r.state.confirmedRecordFor(chk)?.resolution,
      ].firstOrNull;

  /// いちばん大事なことを見出しにする。確定済みの記録と食い違ったら、誰の決定と食い違ったかまで言う
  String _title(Resolution? settled) {
    if (settled != null) {
      return settled.answeredBy == null
          ? '${settled.decidedBy}に確認済みの決定と食い違っています'
          : '${settled.decidedBy}が決めたことと食い違っています';
    }
    final checks = [
      for (final r in records)
        for (final (_, chk) in _items(r)) chk,
    ];
    final conflicts = checks.where((chk) => chk.kind == Kind.contradiction);
    // 相手がどれも資料の行なら、ノートでなく資料と言う（ADR 0019）
    if (conflicts.isNotEmpty) return '${conflicts.every((chk) => chk.materialRef != null) ? '資料' : 'ノート'}と食い違っています';
    final written = checks.where((chk) => chk.kind == Kind.addition || chk.kind == Kind.qualification).length;
    if (written > 0) return 'ノートに$written行書き込みました';
    if (checks.isNotEmpty) {
      return '${checks.every((chk) => chk.materialRef != null) ? '資料' : 'ノート'}と同じ内容でした（記録として残しました）';
    }
    return 'ノートは変えずに、言われた記録として残しました';
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final conflicted = records.any((r) => _items(r).any((x) => x.$2.kind == Kind.contradiction));
    final settled = _settled();
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < k.stackBelow;
        // 食い違いはこのアプリの見せ場なので、見出しを大きくする。食い違いが無ければ落ち着いた見た目のまま
        final title = Text(_title(settled), style: conflicted ? k.text.display : k.text.title);
        final close = MoonButton.icon(
          semanticLabel: '結果を閉じる',
          icon: Icon(LucideIcons.x, color: k.colors.ink),
          onTap: onClose,
        );
        // 確定済みの記録と食い違ったら、誰の決定かを大きめの確認印で見出しに添える。狭い幅では見出しの上に置く
        final stamp = settled == null
            ? null
            : SizedBox.square(
                dimension: k.stampDiameterLarge,
                child: FittedBox(
                  child: ConfirmStamp(who: settled.decidedBy, day: settled.decidedAt, decided: settled.answeredBy != null),
                ),
              );
        return PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.lg, k.space.xl),
          // 黄は面を塗らないのが決まりだが、このカードの食い違いだけは例外（flutter-ui.md）。黄の線で囲み、付箋と見分ける
          tint: conflicted ? (bg: k.colors.pendingBg, line: k.colors.pending) : null,
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
            for (final r in records) ..._note(context, r, stacked: stacked),
            SizedBox(height: k.space.xl),
            Wrap(
              spacing: k.space.md,
              runSpacing: k.space.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 記録した時点では解決を求めない。確認リストに入ったことだけを伝え、中身は「確かめる」で見せる
                if (conflicted) ...[
                  MoonFilledButton(onTap: onReview, label: const Text('確かめる')),
                  Text('確認リストに入れました', style: k.text.small),
                ] else
                  MoonTextButton(onTap: onReview, label: const Text('確かめる')),
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
          ),
          if (s.confirmedRecordFor(chk)?.resolution case final settled?) ..._evidence(context, settled),
        ] else ...[
          SizedBox(height: k.space.sm),
          // 行が折り返しても、分類のタグは1行目にそろえる
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsets.only(top: k.space.xs), child: KindTag(chk.kind)),
            SizedBox(width: k.space.sm),
            Expanded(
              child: Text(
                chk.kind == Kind.same && chk.sameLine != null ? counterpartLine(chk, chk.sameLine!) : plain(p.text),
                style: k.text.body,
              ),
            ),
          ]),
        ],
      if (items.isEmpty && records.length > 1) ...[
        SizedBox(height: k.space.xs),
        Text('このノートは変えずに、記録として残しました', style: k.text.small),
      ],
    ];
  }

  /// 食い違った相手の確定の記録と、相手に見せる文。確認印は見出しに添えたので、ここでは見せる文を主にしてコピーできるようにする
  List<Widget> _evidence(BuildContext context, Resolution r) {
    final k = context.tokens;
    final show = showRecordText(r);
    return [
      SizedBox(height: k.space.md),
      Text('${fmtDay(r.decidedAt)} ${r.decidedBy}${r.verb}：${r.note}', style: k.text.body),
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
    ];
  }
}
