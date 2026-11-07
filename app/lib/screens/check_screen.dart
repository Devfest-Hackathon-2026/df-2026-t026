import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('確定しました。確認の記録に残しています')));
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
    return ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final s = widget.c.state!;
        final chk = s.checks.firstWhere((x) => x.id == widget.checkId);
        final p = s.patch(chk.patchId);
        final u = s.utterance(chk.utteranceId);
        final who = '${u.speaker ?? '発言者未入力'}（${fmtDay(u.saidAt)}）';
        return Scaffold(
          appBar: AppBar(title: Text(chk.isOpen ? '確認が必要です' : '確認の記録')),
          body: Narrow(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 40), children: [
              if (chk.resolution != null) ...[_evidence(chk.resolution!), const SizedBox(height: 24)],
              _step('1', chk.isOpen ? '食い違っていること' : '食い違っていたこと'),
              ConflictPair(leftLabel: 'マニュアル', left: chk.conflictLine ?? '', rightLabel: who, right: p.text),
              const SizedBox(height: 8),
              Text(chk.reason, style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 4),
              Text('元の発言：「${u.text}」', style: const TextStyle(color: Colors.black54, fontSize: 13)),
              if (chk.isOpen) ...[
                const SizedBox(height: 28),
                _step('2', '誰に確認する？'),
                for (final cand in chk.candidates) _candidate(cand),
                if (chk.question != null) ...[const SizedBox(height: 12), _question(chk.question!)],
                const SizedBox(height: 28),
                _step('3', '確認した結果を記録する'),
                _form(chk, p, u),
              ],
            ]),
          ),
        );
      },
    );
  }

  Widget _step(String n, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          CircleAvatar(radius: 12, child: Text(n, style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ]),
      );

  Widget _candidate(AskCandidate cand) {
    final selected = _decidedBy.text.trim() == cand.who;
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(selected ? Icons.check_circle : Icons.person_outline,
            color: selected ? Theme.of(context).colorScheme.primary : null),
        title: Text(cand.who),
        subtitle: Text(cand.why),
        onTap: () => setState(() => _decidedBy.text = cand.who),
      ),
    );
  }

  Widget _question(String q) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('聞き方の例', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(q, style: const TextStyle(height: 1.6)),
          ]),
        ),
        IconButton(
          tooltip: 'コピー',
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: q));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('コピーしました')));
            }
          },
        ),
      ]),
    );
  }

  Widget _form(Check chk, Patch p, Utterance u) {
    final ready = _decidedBy.text.trim().isNotEmpty && (_outcome != _Outcome.custom || _custom.text.trim().isNotEmpty);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _decidedBy,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: '確認した相手', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _pickDate,
          icon: const Icon(Icons.event, size: 18),
          label: Text('${fmtDay(_decidedAt)} に確認'),
        ),
      ),
      const SizedBox(height: 8),
      RadioGroup<_Outcome>(
        groupValue: _outcome,
        onChanged: (v) => setState(() => _outcome = v!),
        child: Column(children: [
          RadioListTile(
            value: _Outcome.keep,
            title: const Text('マニュアルのまま'),
            subtitle: Text(plain(chk.conflictLine ?? '')),
          ),
          RadioListTile(
            value: _Outcome.adopt,
            title: Text('${u.speaker ?? '新しく聞いた方'}の言う通り'),
            subtitle: Text(plain(p.text)),
          ),
          RadioListTile(
            value: _Outcome.custom,
            title: const Text('別の内容に決まった'),
            subtitle: _outcome == _Outcome.custom
                ? TextField(controller: _custom, onChanged: (_) => setState(() {}))
                : null,
          ),
        ]),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _note,
        decoration: const InputDecoration(
          labelText: 'メモ（何と言われたか）',
          hintText: '例: 1/2で統一',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: ready && !_busy ? () => _resolve(chk, p) : null,
          icon: const Icon(Icons.verified),
          label: const Text('確定する'),
        ),
      ),
    ]);
  }

  /// 後で別の人に聞かれたときに見せる記録
  Widget _evidence(Resolution r) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: addBg,
        border: Border.all(color: addFg.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.verified, color: addFg),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${fmtDay(r.decidedAt)} ${r.decidedBy}に確認：${r.note}',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: addFg)),
          ),
        ]),
        const SizedBox(height: 8),
        Text('確定した内容：${plain(r.text)}', style: t.bodyLarge),
      ]),
    );
  }
}
