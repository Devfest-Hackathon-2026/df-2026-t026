import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_screen.dart';
import 'common.dart';
import 'review_dialog.dart';

/// マニュアル1冊の画面：現行マニュアル・入力欄／確認待ち・確認の記録・記録した発言
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

  /// 狭い画面で開いているタブ（0: マニュアル、1: 確認・記録）
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
            PageHeader(title: s?.title ?? '', wide: true),
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
    final manual = _manualPane(s);
    final side = _sidePane(s);
    if (width >= k.wideLayout) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 3, child: manual),
        Container(width: k.hairline, color: k.colors.rule),
        Expanded(flex: 2, child: side),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
        child: MoonTabBar(
          initialIndex: _tab,
          onTabChanged: (i) => setState(() => _tab = i),
          tabs: [
            const MoonTab(label: Text('マニュアル')),
            MoonTab(label: Text(s.openChecks.isEmpty ? '確認・記録' : '確認・記録（${s.openChecks.length}）')),
          ],
        ),
      ),
      Expanded(child: IndexedStack(index: _tab, children: [manual, side])),
    ]);
  }

  Widget _manualPane(ManualState s) {
    final k = context.tokens;
    final changed = s.lines.where((l) => l.patchId != null).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(padding: EdgeInsets.all(k.space.lg), children: [
          Text('元のマニュアル ＋ 口頭で教わった差分 $changed 行', style: k.text.small),
          SizedBox(height: k.space.sm),
          // マニュアル本文は「紙」として面を分ける
          Container(
            padding: EdgeInsets.symmetric(vertical: k.space.md),
            decoration: BoxDecoration(
              color: k.colors.sheet,
              border: Border.all(color: k.colors.rule, width: k.hairline),
              borderRadius: k.radius.surface,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final line in s.lines) _line(s, line),
            ]),
          ),
        ]),
      ),
      _composer(),
    ]);
  }

  Widget _line(ManualState s, ManualLine line) {
    final k = context.tokens;
    if (line.text.trim().isEmpty) return SizedBox(height: k.space.sm);
    if (line.text.startsWith('## ')) {
      return Padding(
        padding: EdgeInsets.fromLTRB(k.gutter, k.space.md, k.space.lg, k.space.xs),
        child: LineText(line.text),
      );
    }
    final open = s.openChecksFor(line);
    final confirmed = s.confirmationFor(line);
    final patch = line.patchId == null ? null : s.patch(line.patchId!);
    final said = patch == null ? null : s.utterance(patch.utteranceId);
    final fromSpeech = patch != null || confirmed != null;
    final marks = <Widget>[
      if (confirmed != null)
        ConfirmStamp(
          compact: true,
          who: confirmed.resolution!.decidedBy,
          day: confirmed.resolution!.decidedAt,
          onTap: () => _openCheck(confirmed),
        )
      else if (said != null)
        SpeakerTape(speaker: said.speaker, day: said.saidAt, onTap: () => _showUtterance(said)),
      for (final o in open)
        MoonTag(
          tagSize: MoonTagSize.xs,
          backgroundColor: k.colors.pending,
          borderRadius: k.radius.control,
          onTap: () => _openCheck(o),
          leading: Icon(LucideIcons.circleAlert, color: k.colors.pendingBg),
          label: Text('確認待ち', style: k.text.label.copyWith(color: k.colors.pendingBg)),
        ),
    ];
    final text = LineText(line.text);
    return Container(
      color: open.isNotEmpty ? k.colors.pendingBg : (fromSpeech ? k.colors.addedBg : null),
      padding: EdgeInsets.fromLTRB(0, k.space.xs, k.space.lg, k.space.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 差分の行頭の印。口頭で教わって変わった行に「+」
        SizedBox(
          width: k.gutter,
          child: Text(fromSpeech ? '+' : '', textAlign: TextAlign.center, style: k.text.body.copyWith(color: k.colors.added)),
        ),
        Expanded(
          child: Wrap(
            spacing: k.space.sm,
            runSpacing: k.space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [text, ...marks],
          ),
        ),
      ]),
    );
  }

  void _showUtterance(Utterance u) {
    final k = context.tokens;
    showMoonModal<void>(
      context: context,
      builder: (ctx) => MoonModal(
        backgroundColor: k.colors.sheet,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）', style: k.text.heading),
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

  Widget _composer() {
    final k = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: k.colors.sheet,
        border: Border(top: BorderSide(color: k.colors.rule, width: k.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('言われたことを記録', style: k.text.small),
        SizedBox(height: k.space.sm),
        Row(children: [
          Expanded(
            child: MoonTextInput(
              controller: _input,
              onSubmitted: (_) => _record(),
              hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
            ),
          ),
          SizedBox(width: k.space.sm),
          MoonFilledButton(
            onTap: _busy ? null : _record,
            leading: _busy ? const ButtonLoader() : null,
            label: Text(_busy ? '差分を作成中…' : '差分を作る'),
          ),
        ]),
      ]),
    );
  }

  Widget _sidePane(ManualState s) {
    final k = context.tokens;
    Widget empty(String text) => Padding(
          padding: EdgeInsets.symmetric(horizontal: k.space.lg),
          child: Text(text, style: k.text.small),
        );

    return ListView(padding: EdgeInsets.only(bottom: k.space.xl), children: [
      SectionHeading('確認待ち（${s.openChecks.length}）'),
      if (s.openChecks.isEmpty) empty('食い違っている指示はありません'),
      for (final chk in s.openChecks.reversed) _openRow(s, chk),
      SectionHeading('確認の記録（${s.resolvedChecks.length}）'),
      if (s.resolvedChecks.isEmpty) empty('確認して確定したことがここに残ります'),
      for (final chk in s.resolvedChecks.reversed) ...[_resolvedRow(chk), Rule(indent: k.space.lg)],
      SectionHeading('記録した発言（${s.utterances.length}）'),
      if (s.utterances.isEmpty) empty('下の欄に言われたことを書くと、ここに並びます'),
      for (final u in s.utterances.reversed) ...[_utteranceRow(s, u), Rule(indent: k.space.lg)],
    ]);
  }

  /// 確認待ちは付箋の色で、他の記録と分ける
  Widget _openRow(ManualState s, Check chk) {
    final k = context.tokens;
    final p = s.patch(chk.patchId);
    final u = s.utterance(chk.utteranceId);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.xs),
      child: MoonMenuItem(
        backgroundColor: k.colors.pendingBg,
        borderRadius: k.radius.control,
        onTap: () => _openCheck(chk),
        label: Text('${plain(chk.conflictLine ?? '')} ／ ${plain(p.text)}', style: k.text.body),
        content: Text('マニュアル ／ ${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）',
            style: k.text.small.copyWith(color: k.colors.pending)),
        trailing: Icon(LucideIcons.chevronRight, color: k.colors.pending),
      ),
    );
  }

  Widget _resolvedRow(Check chk) {
    final k = context.tokens;
    final r = chk.resolution!;
    return MoonMenuItem(
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
      onTap: () => _openCheck(chk),
      label: Text('${fmtDay(r.decidedAt)} ${r.decidedBy}に確認：${r.note}', style: k.text.body),
      content: r.note == plain(r.text) ? null : Text('→ ${plain(r.text)}', style: k.text.small),
    );
  }

  Widget _utteranceRow(ManualState s, Utterance u) {
    final k = context.tokens;
    return MoonMenuItem(
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
      onTap: () => showReview(context, c, u.id),
      label: Text(u.text, style: k.text.hand),
      content: Padding(
        padding: EdgeInsets.only(top: k.space.xs),
        child: Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${u.speaker ?? '発言者未入力'} ${fmtDay(u.saidAt)}', style: k.text.small),
          for (final st in _statuses(s, u)) _statusTag(st),
        ]),
      ),
    );
  }

  Widget _statusTag(String status) {
    final k = context.tokens;
    final c = k.colors;
    final (bg, fg) = switch (status) {
      '確認待ち' => (c.pendingBg, c.pending),
      '確認済み' || '反映済み' => (c.addedBg, c.added),
      '確認の答え' => (c.sheet, c.stamp),
      _ => (c.rule, c.ink),
    };
    return MoonTag(
      tagSize: MoonTagSize.xs,
      backgroundColor: bg,
      borderRadius: k.radius.control,
      label: Text(status, style: k.text.label.copyWith(color: fg)),
    );
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
