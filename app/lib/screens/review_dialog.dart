import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import 'check_screen.dart';
import 'common.dart';

Future<void> showReview(BuildContext context, ManualController c, String utteranceId) => showDialog(
      context: context,
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
  late final Utterance _u = widget.c.state!.utterance(widget.utteranceId);
  late final _speaker = TextEditingController(text: _u.speaker ?? '');
  late String _saidAt = _u.saidAt;
  final _editing = <String, TextEditingController>{};
  var _busy = false;

  bool get _hasSpeaker => _speaker.text.trim().isNotEmpty;

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
    return ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final s = widget.c.state!;
        final patches = s.patchesOf(_u.id);
        return AlertDialog(
          title: const Text('差分の確認'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('「${_u.text}」', style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 16),
                TextField(
                  controller: _speaker,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '誰が言った？',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _hasSpeaker ? null : '反映する前に入れてください',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event, size: 18),
                  label: Text('${fmtDay(_saidAt)} に言われた'),
                ),
                const SizedBox(height: 16),
                if (patches.isEmpty) const Text('マニュアルに関わる内容は見つかりませんでした。発言の記録だけ残しています。'),
                for (final p in patches) ...[_patchCard(s, p), const SizedBox(height: 12)],
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる'))],
        );
      },
    );
  }

  Widget _patchCard(ManualState s, Patch p) {
    final chk = s.checkOf(p.id);
    final t = Theme.of(context).textTheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (chk != null) ...[KindChip(chk.kind), const SizedBox(width: 8)],
            Expanded(child: Text(p.summary, style: t.titleSmall)),
          ]),
          if (chk != null) ...[
            const SizedBox(height: 4),
            Text(chk.reason, style: t.bodySmall?.copyWith(color: Colors.black54)),
          ],
          const SizedBox(height: 10),
          if (chk?.kind == Kind.contradiction) ..._contradiction(s, p, chk!) else ..._approvable(p),
        ]),
      ),
    );
  }

  List<Widget> _contradiction(ManualState s, Patch p, Check chk) => [
        ConflictPair(
          leftLabel: 'マニュアル',
          left: chk.conflictLine ?? '',
          rightLabel: '${_hasSpeaker ? _speaker.text.trim() : '発言者未入力'}（${fmtDay(_saidAt)}）',
          right: p.text,
        ),
        const SizedBox(height: 10),
        if (chk.resolution != null)
          Text('${fmtDay(chk.resolution!.decidedAt)} ${chk.resolution!.decidedBy}に確認して確定済み',
              style: const TextStyle(color: addFg))
        else ...[
          const Text('どちらが正しいかはアプリでは決めません。確認してから確定します。', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        if (!mounted) return;
                        final nav = Navigator.of(context);
                        nav.pop();
                        await nav.push(MaterialPageRoute(builder: (_) => CheckScreen(c: widget.c, checkId: chk.id)));
                      }),
              icon: const Icon(Icons.forum_outlined),
              label: const Text('誰に確認するか見る'),
            ),
          ),
        ],
      ];

  List<Widget> _approvable(Patch p) {
    final edit = _editing[p.id];
    return [
      if (edit == null)
        PatchDiff(op: p.op, line: p.line, text: p.text)
      else
        TextField(
          controller: edit,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: '反映する内容を修正'),
        ),
      const SizedBox(height: 8),
      if (p.status != 'proposed')
        Text(p.status == 'applied' ? '反映済み' : '反映しない', style: const TextStyle(color: Colors.black54))
      else
        Row(children: [
          TextButton(
            onPressed: _busy ? null : () => _run(() => widget.c.discardPatch(p.id)),
            child: const Text('反映しない'),
          ),
          TextButton(
            onPressed: () => setState(() {
              if (edit == null) {
                _editing[p.id] = TextEditingController(text: p.text);
              } else {
                _editing.remove(p.id);
              }
            }),
            child: Text(edit == null ? '修正' : '修正をやめる'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: _busy || !_hasSpeaker
                ? null
                : () => _run(() => widget.c.applyPatch(p.id, text: edit?.text.trim())),
            child: const Text('承認して反映'),
          ),
        ]),
    ];
  }
}
