import 'package:flutter/material.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
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
          appBar: AppBar(title: Text(s?.title ?? '')),
          body: s == null
              ? Center(child: c.loadError != null ? Text(c.loadError!) : const CircularProgressIndicator())
              : LayoutBuilder(builder: (context, box) {
                  final manual = _manualPane(s);
                  final side = _sidePane(s);
                  if (box.maxWidth >= 900) {
                    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: manual),
                      const VerticalDivider(width: 1),
                      Expanded(flex: 2, child: side),
                    ]);
                  }
                  return DefaultTabController(
                    length: 2,
                    child: Column(children: [
                      TabBar(tabs: [
                        const Tab(text: 'マニュアル'),
                        Tab(text: s.openChecks.isEmpty ? '確認・記録' : '確認・記録（${s.openChecks.length}）'),
                      ]),
                      Expanded(child: TabBarView(children: [manual, side])),
                    ]),
                  );
                }),
        );
      },
    );
  }

  Widget _manualPane(ManualState s) {
    final t = Theme.of(context).textTheme;
    final changed = s.lines.where((l) => l.patchId != null).length;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 20), children: [
          Text('元のマニュアル ＋ 口頭で教わった差分 $changed 行', style: t.bodySmall?.copyWith(color: Colors.black54)),
          const SizedBox(height: 8),
          for (final line in s.lines) _line(s, line),
        ]),
      ),
      _composer(),
    ]);
  }

  Widget _line(ManualState s, ManualLine line) {
    if (line.text.trim().isEmpty) return const SizedBox(height: 8);
    if (line.text.startsWith('## ')) {
      return Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: LineText(line.text));
    }
    final open = s.openChecksFor(line);
    final confirmed = s.confirmationFor(line);
    final patch = line.patchId == null ? null : s.patch(line.patchId!);
    final said = patch == null ? null : s.utterance(patch.utteranceId);
    final chips = <Widget>[
      if (confirmed != null)
        _chip(Icons.verified, '${confirmed.resolution!.decidedBy}に確認 ${fmtDay(confirmed.resolution!.decidedAt)}',
            addFg, () => _openCheck(confirmed))
      else if (said != null)
        _chip(Icons.record_voice_over, '${said.speaker} ${fmtDay(said.saidAt)}', Colors.black54,
            () => _showUtterance(said)),
      for (final o in open) _chip(Icons.error_outline, '確認待ち', warnFg, () => _openCheck(o)),
    ];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: open.isNotEmpty ? warnBg : null,
        border: Border(
          left: BorderSide(color: patch != null || confirmed != null ? addFg : Colors.transparent, width: 3),
        ),
      ),
      child: MediaQuery.sizeOf(context).width < 600 && chips.isNotEmpty
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LineText(line.text),
              Wrap(children: chips),
            ])
          : Row(children: [Expanded(child: LineText(line.text)), ...chips]),
    );
  }

  Widget _chip(IconData icon, String label, Color color, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: ActionChip(
          avatar: Icon(icon, size: 16, color: color),
          label: Text(label, style: TextStyle(fontSize: 12, color: color)),
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        ),
      );

  void _showUtterance(Utterance u) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）'),
          content: Text('「${u.text}」'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('閉じる'))],
        ),
      );

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('言われたことを記録', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                onSubmitted: (_) => _record(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _record,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.difference),
              label: Text(_busy ? '差分を作成中…' : '差分を作る'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _sidePane(ManualState s) {
    final t = Theme.of(context).textTheme;
    Widget header(String text) =>
        Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(text, style: t.titleSmall));
    Widget empty(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(text, style: t.bodySmall?.copyWith(color: Colors.black45)));

    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      header('確認待ち（${s.openChecks.length}）'),
      if (s.openChecks.isEmpty) empty('食い違っている指示はありません'),
      for (final chk in s.openChecks.reversed) _openTile(s, chk),
      header('確認の記録（${s.resolvedChecks.length}）'),
      if (s.resolvedChecks.isEmpty) empty('確認して確定したことがここに残ります'),
      for (final chk in s.resolvedChecks.reversed)
        ListTile(
          leading: const Icon(Icons.verified, color: addFg),
          title: Text('${fmtDay(chk.resolution!.decidedAt)} ${chk.resolution!.decidedBy}に確認：${chk.resolution!.note}'),
          subtitle: chk.resolution!.note == plain(chk.resolution!.text)
              ? null
              : Text('→ ${plain(chk.resolution!.text)}'),
          onTap: () => _openCheck(chk),
        ),
      header('記録した発言（${s.utterances.length}）'),
      for (final u in s.utterances.reversed)
        ListTile(
          leading: const CircleAvatar(radius: 16, child: Icon(Icons.record_voice_over, size: 16)),
          title: Text(u.text),
          subtitle: Text('${u.speaker ?? '発言者未入力'} ・ ${fmtDay(u.saidAt)} ・ ${_status(s, u)}'),
          onTap: () => showReview(context, c, u.id),
        ),
    ]);
  }

  Widget _openTile(ManualState s, Check chk) {
    final p = s.patch(chk.patchId);
    final u = s.utterance(chk.utteranceId);
    return Card(
      color: warnBg,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.error_outline, color: warnFg),
        title: Text('${plain(chk.conflictLine ?? '')} ／ ${plain(p.text)}'),
        subtitle: Text('マニュアル ／ ${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openCheck(chk),
      ),
    );
  }

  String _status(ManualState s, Utterance u) {
    if (s.resolvedChecks.any((c) => c.resolution!.utteranceId == u.id)) return '確認の答え';
    final patches = s.patchesOf(u.id);
    if (patches.isEmpty) return '差分なし';
    return patches.map((p) {
      final chk = s.checkOf(p.id);
      if (chk?.resolution != null) return '確認済み';
      if (chk?.isOpen ?? false) return '確認待ち';
      return switch (p.status) { 'applied' => '反映済み', 'discarded' => '反映しない', _ => '未反映' };
    }).join('・');
  }
}
