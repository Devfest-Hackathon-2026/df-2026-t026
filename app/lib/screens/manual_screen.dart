import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'review_dialog.dart';

/// マニュアル1冊の画面：文書面（現行マニュアル）と、記録した発言のパネル。食い違いは確認リスト（別の画面）にまとめる
class ManualScreen extends StatefulWidget {
  const ManualScreen({super.key, required this.api, required this.manualId});
  final Api api;
  final String manualId;

  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  late final c = ManualController(widget.api, widget.manualId)..load();
  final _input = TextEditingController();
  var _busy = false;

  /// 狭い画面で開いているタブ（0: マニュアル、1: 発言）
  var _tab = 0;

  @override
  void dispose() {
    c.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final String id;
    try {
      id = await c.record(text);
      _input.clear();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await showReview(context, c, id);
  }

  void _openCheck(Check check) => openCheckViaList(Navigator.of(context), c, check.id);

  void _openList() => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckListScreen(c: c)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        final open = s?.openChecks.length ?? 0;
        return Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(
              crumbs: ['DiffNote（仮）', s?.title ?? ''],
              trailing: s == null
                  ? null
                  : MoonOutlinedButton(
                      buttonSize: MoonButtonSize.sm,
                      onTap: _openList,
                      label: Text(open == 0 ? '確認リスト' : '確認リスト $open'),
                    ),
            ),
            Expanded(
              child: PopBackground(
                child: s == null
                    ? (c.loadError != null ? LoadFailed(message: c.loadError!, onRetry: c.load) : const Loading())
                    : LayoutBuilder(builder: (context, box) => _layout(s, box.maxWidth)),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _layout(ManualState s, double width) {
    final k = context.tokens;
    if (width >= k.wideLayout) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _document(s)),
        Container(width: k.hairline, color: k.colors.rule),
        SizedBox(
          width: k.panelWidth,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _utterances(s, withHeader: true)),
            _composer(stacked: true),
          ]),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
        child: GlassTabs(
          labels: ['マニュアル', '発言 ${s.utterances.length}'],
          emojis: const ['📖', '💬'],
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
        ),
      ),
      Expanded(child: _tab == 0 ? _document(s) : _utterances(s, withHeader: false)),
      _composer(stacked: false),
    ]);
  }

  /// 文書面：題名・メタ情報・本文。白い紙にテープで留めた形で見せる
  Widget _document(ManualState s) {
    final k = context.tokens;
    final changed = s.lines.where((l) => l.patchId != null).length;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.xxl),
      child: Narrow(
        child: PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xxl, k.space.xl, k.space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.only(left: k.gutter),
              child: PageTitle(s.title, meta: [
                Text('記録 ${s.utterances.length} 件', style: k.text.small),
                Text('口頭で変わった行 $changed 行', style: k.text.small),
                if (s.openChecks.isNotEmpty)
                  StatusTag('あとで確認 ${s.openChecks.length} 件',
                      bg: k.colors.pendingBg, fg: k.colors.pending, onTap: _openList, emoji: '📌'),
              ]),
            ),
            SizedBox(height: k.space.xl),
            for (final line in s.lines) _line(s, line),
          ]),
        ),
      ),
    );
  }

  Widget _line(ManualState s, ManualLine line) {
    final k = context.tokens;
    if (line.text.trim().isEmpty) return SizedBox(height: k.space.sm);
    if (line.text.startsWith('## ')) {
      return Padding(
        padding: EdgeInsets.fromLTRB(k.gutter, k.space.xl, 0, k.space.xs),
        child: LineText(line.text),
      );
    }
    final open = s.openChecksFor(line);
    final confirmed = s.confirmationFor(line);
    final patch = line.patchId == null ? null : s.patch(line.patchId!);
    final said = patch == null ? null : s.utterance(patch.utteranceId);
    // 左余白の色線は変更の種類を表す：あとで確認は黄、口頭で変わった行は緑。食い違いでも行の地は塗らない
    final bar = open.isNotEmpty ? k.colors.pending : (patch != null || confirmed != null ? k.colors.added : null);
    final marks = <Widget>[
      if (confirmed != null)
        ConfirmStamp(
          compact: true,
          who: confirmed.resolution!.decidedBy,
          day: confirmed.resolution!.decidedAt,
          onTap: () => _openCheck(confirmed),
        )
      else if (said != null)
        Speaker(name: said.speaker, day: said.saidAt, onTap: () => _showUtterance(said)),
      // 食い違っていることをその場で見せる：「マニュアルの行 ／ 誰（日付）：言われたこと」
      for (final o in open)
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('／', style: k.text.body.copyWith(color: k.colors.pending)),
          Text('${s.utterance(o.utteranceId).speaker ?? '発言者未入力'}（${fmtDay(s.utterance(o.utteranceId).saidAt)}）：',
              style: k.text.small),
          Text(plain(s.patch(o.patchId).text), style: k.text.hand),
          StatusTag('食い違い', bg: k.colors.pendingBg, fg: k.colors.pending, emoji: '⚡'),
        ]),
    ];
    final row = IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: k.gutter,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(width: k.changeBar, color: bar),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: k.space.xs),
            child: Wrap(
              spacing: k.space.md,
              runSpacing: k.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [LineText(line.text), ...marks],
            ),
          ),
        ),
      ]),
    );
    if (open.isEmpty) return row;
    // 食い違っている行は、どこを押しても確認リストを開く。その場では解決させない
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _openList, child: row),
    );
  }

  void _showUtterance(Utterance u) {
    final k = context.tokens;
    showMoonModal<void>(
      context: context,
      builder: (ctx) => MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Speaker(name: u.speaker, day: u.saidAt),
              SizedBox(height: k.space.md),
              Text('「${u.text}」', style: k.text.hand),
              SizedBox(height: k.space.xl),
              MoonOutlinedButton(label: const Text('閉じる'), onTap: () => Navigator.pop(ctx)),
            ]),
          ),
        ),
      ),
    );
  }

  /// 記録の入力欄。広い画面ではパネルの下に縦に積み、狭い画面では画面の下に横に並べる
  Widget _composer({required bool stacked}) {
    final k = context.tokens;
    final input = MoonTextInput(
      controller: _input,
      onSubmitted: (_) => _record(),
      hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
    );
    final button = MoonFilledButton(
      onTap: _busy ? null : _record,
      leading: _busy ? const ButtonLoader() : null,
      label: Text(_busy ? '差分を作成中…' : '差分を作る'),
    );
    return Container(
      decoration: BoxDecoration(
        color: k.colors.glass,
        border: Border(top: BorderSide(color: k.colors.canvas, width: k.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('💬', style: k.text.small),
          SizedBox(width: k.space.xs),
          Text('言われたことを記録', style: k.text.small),
        ]),
        SizedBox(height: k.space.sm),
        if (stacked) ...[
          input,
          SizedBox(height: k.space.sm),
          Align(alignment: Alignment.centerRight, child: button),
        ] else
          Row(children: [Expanded(child: input), SizedBox(width: k.space.sm), button]),
      ]),
    );
  }

  /// 記録した発言のパネル。withHeader が false なら一覧だけ（狭い画面のタブの中身）
  Widget _utterances(ManualState s, {required bool withHeader}) {
    final k = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (withHeader)
        Padding(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.md),
          child: Row(children: [
            Text('💬', style: k.text.title),
            SizedBox(width: k.space.sm),
            Text('記録した発言（${s.utterances.length}）', style: k.text.title),
          ]),
        ),
      Expanded(
        child: s.utterances.isEmpty
            ? Padding(
                padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
                child: Text('言われたことを下の欄に書くと、ここに付箋で並びます', style: k.text.small),
              )
            : ListView(
                padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg),
                children: [
                  for (final u in s.utterances.reversed) ...[
                    _utteranceEntry(s, u),
                    SizedBox(height: k.space.lg),
                  ],
                ],
              ),
      ),
    ]);
  }

  /// 発言：誰が・いつ → 言われたこと（手書き）→ 状態。付箋で見せる
  Widget _utteranceEntry(ManualState s, Utterance u) {
    final k = context.tokens;
    final seed = (u.speaker ?? u.id).codeUnits.fold(0, (a, b) => a + b);
    return StickyNote(
      seed: seed,
      onTap: () => showReview(context, c, u.id),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Speaker(name: u.speaker, day: u.saidAt),
        SizedBox(height: k.space.sm),
        Text(u.text, style: k.text.hand),
        SizedBox(height: k.space.sm),
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, children: [
          for (final st in _statuses(s, u)) _statusTag(st),
        ]),
      ]),
    );
  }

  Widget _statusTag(String status) {
    final c = context.tokens.colors;
    final (bg, fg) = switch (status) {
      'あとで確認' => (c.pendingBg, c.pending),
      '確認済み' || '反映済み' => (c.addedBg, c.added),
      '確認の答え' => (c.canvas, c.stamp),
      _ => (c.rule, c.ink),
    };
    final emoji = switch (status) {
      'あとで確認' => '📌',
      '確認済み' || '反映済み' => '✅',
      '確認の答え' => '💮',
      _ => null,
    };
    return StatusTag(status, bg: bg, fg: fg, emoji: emoji);
  }

  List<String> _statuses(ManualState s, Utterance u) {
    if (s.resolvedChecks.any((c) => c.resolution!.utteranceId == u.id)) return ['確認の答え'];
    final patches = s.patchesOf(u.id);
    if (patches.isEmpty) return ['差分なし'];
    return patches.map((p) {
      final chk = s.checkOf(p.id);
      if (chk?.resolution != null) return '確認済み';
      if (chk?.isOpen ?? false) return 'あとで確認';
      return switch (p.status) { 'applied' => '反映済み', 'discarded' => '反映しない', _ => '未反映' };
    }).toList();
  }
}
