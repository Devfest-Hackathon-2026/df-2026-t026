import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_screen.dart';
import 'common.dart';
import 'review_dialog.dart';

/// マニュアル1冊の画面：文書面（現行マニュアル）と、記録と確認のパネル
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

  /// 狭い画面で開いているタブ（0: マニュアル、1〜3: パネルの切り替えと同じ）
  var _tab = 0;

  /// パネルの切り替え（0: 確認待ち、1: 確認済み、2: 発言）。読み込み後に一度だけ決め、以後は利用者の選択に任せる
  int? _filter;

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

  void _openCheck(Check check) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => CheckScreen(c: c, checkId: check.id)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        return Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: ['DiffNote（仮）', s?.title ?? '']),
            Expanded(
              child: s == null
                  ? (c.loadError != null ? LoadFailed(message: c.loadError!, onRetry: c.load) : const Loading())
                  : LayoutBuilder(builder: (context, box) => _layout(s, box.maxWidth)),
            ),
          ]),
        );
      },
    );
  }

  Widget _layout(ManualState s, double width) {
    final k = context.tokens;
    _filter ??= s.openChecks.isNotEmpty ? 0 : 2;
    if (width >= k.wideLayout) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _document(s)),
        Container(width: k.hairline, color: k.colors.rule),
        SizedBox(
          width: k.panelWidth,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _panel(s, withHeader: true)),
            _composer(stacked: true),
          ]),
        ),
      ]);
    }
    // 狭い画面ではパネルの切り替えをタブに並べ、タブの中にさらに切り替えを重ねない
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // 幅が足りないときはタブを横にスクロールさせる
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.sm),
        child: MoonTabBar(
          tabBarSize: MoonTabBarSize.sm,
          initialIndex: _tab,
          onTabChanged: (i) => setState(() {
            _tab = i;
            if (i > 0) _filter = i - 1;
          }),
          tabs: [
            const MoonTab(label: Text('マニュアル')),
            MoonTab(label: Text('確認待ち ${s.openChecks.length}')),
            MoonTab(label: Text('確認済み ${s.resolvedChecks.length}')),
            MoonTab(label: Text('発言 ${s.utterances.length}')),
          ],
        ),
      ),
      Expanded(child: _tab == 0 ? _document(s) : _panel(s, withHeader: false)),
      _composer(stacked: false),
    ]);
  }

  /// 文書面：題名・メタ情報・本文
  Widget _document(ManualState s) {
    final k = context.tokens;
    final changed = s.lines.where((l) => l.patchId != null).length;
    return Container(
      color: k.colors.canvas,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xxl, k.space.xl, k.space.xxl),
        child: Narrow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.only(left: k.gutter),
              child: PageTitle(s.title, meta: [
                Text('記録 ${s.utterances.length} 件', style: k.text.small),
                Text('口頭で変わった行 $changed 行', style: k.text.small),
                if (s.openChecks.isNotEmpty)
                  StatusTag('確認待ち ${s.openChecks.length} 件', bg: k.colors.pendingBg, fg: k.colors.pending),
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
    // 左余白の色線は変更の種類を表す：確認待ちは黄、口頭で変わった行は緑
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
      for (final o in open)
        StatusTag('確認待ち', bg: k.colors.pending, fg: k.colors.pendingBg, onTap: () => _openCheck(o)),
    ];
    return Container(
      color: open.isNotEmpty ? k.colors.pendingBg : null,
      child: IntrinsicHeight(
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
      ),
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
        color: k.colors.shell,
        border: Border(top: BorderSide(color: k.colors.rule, width: k.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('言われたことを記録', style: k.text.small),
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

  /// 記録と確認のパネル：見出し・切り替え・項目。withHeader が false なら項目だけ（狭い画面のタブの中身）
  Widget _panel(ManualState s, {required bool withHeader}) {
    final k = context.tokens;
    final filter = _filter!;
    final entries = switch (filter) {
      0 => [for (final chk in s.openChecks.reversed) _openEntry(s, chk)],
      1 => [for (final chk in s.resolvedChecks.reversed) _resolvedEntry(s, chk)],
      _ => [for (final u in s.utterances.reversed) _utteranceEntry(s, u)],
    };
    final empty = switch (filter) {
      0 => '食い違っている指示はありません',
      1 => '確認して確定したことがここに残ります',
      _ => '言われたことを下の欄に書くと、ここに並びます',
    };
    return Container(
      color: k.colors.shell,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (withHeader) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.md),
            child: Text('記録と確認', style: k.text.title),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: k.space.lg),
            child: MoonSegmentedControl(
              isExpanded: true,
              backgroundColor: k.colors.rule,
              initialIndex: filter,
              onSegmentChanged: (i) => setState(() => _filter = i),
              segments: [
                Segment(label: const Text('確認待ち'), trailing: Text('${s.openChecks.length}')),
                Segment(label: const Text('確認済み'), trailing: Text('${s.resolvedChecks.length}')),
                Segment(label: const Text('発言'), trailing: Text('${s.utterances.length}')),
              ],
            ),
          ),
        ],
        SizedBox(height: k.space.md),
        Expanded(
          child: entries.isEmpty
              ? Padding(
                  padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
                  child: Text(empty, style: k.text.small),
                )
              : ListView(children: [
                  for (final e in entries) ...[e, const Rule()],
                ]),
        ),
      ]),
    );
  }

  Widget _entry({required VoidCallback onTap, required Widget head, required List<Widget> body}) {
    final k = context.tokens;
    return MoonMenuItem(
      onTap: onTap,
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
      label: head,
      content: Padding(
        padding: EdgeInsets.only(top: k.space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body),
      ),
    );
  }

  /// 確認待ち：誰が・いつ → 食い違い（マニュアル ／ 言われたこと）→ 次の操作
  Widget _openEntry(ManualState s, Check chk) {
    final k = context.tokens;
    final p = s.patch(chk.patchId);
    final u = s.utterance(chk.utteranceId);
    return _entry(
      onTap: () => _openCheck(chk),
      head: Speaker(name: u.speaker, day: u.saidAt),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(p.text)}', style: k.text.heading),
        SizedBox(height: k.space.xs),
        Text(chk.reason, style: k.text.small),
        SizedBox(height: k.space.md),
        MoonOutlinedButton(
          buttonSize: MoonButtonSize.sm,
          onTap: () => _openCheck(chk),
          label: const Text('誰に確認するか見る'),
        ),
      ],
    );
  }

  /// 確認済み：誰が・いつ言ったか → 食い違っていたこと → 誰がいつ確認して何に決まったか
  Widget _resolvedEntry(ManualState s, Check chk) {
    final k = context.tokens;
    final p = s.patch(chk.patchId);
    final u = s.utterance(chk.utteranceId);
    final r = chk.resolution!;
    return _entry(
      onTap: () => _openCheck(chk),
      head: Speaker(name: u.speaker, day: u.saidAt),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(p.text)}', style: k.text.small),
        SizedBox(height: k.space.sm),
        Row(children: [
          ConfirmStamp(compact: true, who: r.decidedBy, day: r.decidedAt),
          SizedBox(width: k.space.sm),
          Expanded(child: Text(r.note, style: k.text.body)),
        ]),
        if (r.note != plain(r.text)) ...[
          SizedBox(height: k.space.xs),
          Text('確定した内容：${plain(r.text)}', style: k.text.small),
        ],
      ],
    );
  }

  /// 発言：誰が・いつ → 言われたこと（手書き）→ 状態
  Widget _utteranceEntry(ManualState s, Utterance u) {
    final k = context.tokens;
    return _entry(
      onTap: () => showReview(context, c, u.id),
      head: Speaker(name: u.speaker, day: u.saidAt),
      body: [
        Text(u.text, style: k.text.hand),
        SizedBox(height: k.space.sm),
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, children: [
          for (final st in _statuses(s, u)) _statusTag(st),
        ]),
      ],
    );
  }

  Widget _statusTag(String status) {
    final c = context.tokens.colors;
    final (bg, fg) = switch (status) {
      '確認待ち' => (c.pendingBg, c.pending),
      '確認済み' || '反映済み' => (c.addedBg, c.added),
      '確認の答え' => (c.canvas, c.stamp),
      _ => (c.rule, c.ink),
    };
    return StatusTag(status, bg: bg, fg: fg);
  }

  List<String> _statuses(ManualState s, Utterance u) {
    if (s.resolvedChecks.any((c) => c.resolution!.utteranceId == u.id)) return ['確認の答え'];
    final patches = s.patchesOf(u.id);
    if (patches.isEmpty) return ['差分なし'];
    return patches.map((p) {
      final chk = s.checkOf(p.id);
      if (chk?.resolution != null) return '確認済み';
      if (chk?.isOpen ?? false) return '確認待ち';
      return switch (p.status) { 'applied' => '反映済み', 'discarded' => '反映しない', _ => '未反映' };
    }).toList();
  }
}
