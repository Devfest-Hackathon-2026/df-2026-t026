import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'tab_bar.dart';

/// 発言者の候補に並べる数
const _maxSpeakers = 6;

/// 1冊のノートに記録した、言われたこと。入力ページからは関係するノートごとに1件ずつできる
typedef ReviewTarget = ({ManualController c, String utteranceId});

// 外側を押して閉じると発言者と日付の変更が保存されないので、閉じるボタンだけで閉じる
Future<void> showReview(BuildContext context, List<ReviewTarget> targets) => showMoonModal<void>(
      context: context,
      barrierDismissible: false,
      // ノートの画面から開いたときは、確認リストを「ノートの上」として開く（下のタブバーの「ノート」で1枚のノートに戻る）
      builder: (_) =>
          ReviewDialog(targets: targets, listSettings: aboveNote(context, fromNote: context.widget is ManualScreen)),
    );

/// 記録した後、迷う所が無ければ確認を開かずに書き込み、知らせの「確かめる」から確認を開けるようにする。
/// 発言者が分からないか、分類の付いていない差分があれば確認を開く。食い違いは確認リストに入っているので触らない
Future<void> writeOrReview(BuildContext context, List<ReviewTarget> targets) async {
  final clear = targets.every((t) {
    final s = t.c.state!;
    return s.utterance(t.utteranceId).speaker != null &&
        s.patchesOf(t.utteranceId).every((p) => p.status != 'proposed' || s.checkOf(p.id) != null);
  });
  if (!clear) return showReview(context, targets);
  var written = 0;
  var conflicts = 0;
  // 同じノートの差分は前の書き込みの結果に重ねるので順に送る。ノートが違えば並べて送る
  await Future.wait([
    for (final t in targets)
      () async {
        // 書き込むたびに状態が置き換わるので、分類は先に控えておく
        final s = t.c.state!;
        final kinds = {for (final p in s.patchesOf(t.utteranceId)) if (p.status == 'proposed') p: s.checkOf(p.id)!.kind};
        for (final MapEntry(key: p, value: kind) in kinds.entries) {
          switch (kind) {
            case Kind.addition || Kind.qualification:
              await t.c.applyPatch(p.id);
              written++;
            case Kind.same:
              await t.c.discardPatch(p.id);
            case Kind.contradiction:
              conflicts++;
          }
        }
      }(),
  ]);
  if (!context.mounted) return;
  final message = [
    if (written > 0) 'ノートに$written行書き込みました',
    if (conflicts > 0) '食い違いが$conflicts件あり、確認リストに入れました',
  ].join('。');
  showToast(
    context,
    message.isEmpty ? 'ノートは変えずに、言われた記録として残しました' : message,
    action: (label: '確かめる', onTap: () => context.mounted ? showReview(context, targets) : null),
  );
}

/// 差分化と分類の結果を見て、発言者と日付を確かめてから反映する。
/// 1つの発言が複数のノートに関わるときは、発言者と日付を1回だけ入れ、ノートごとの変わる行を上下に並べる
class ReviewDialog extends StatefulWidget {
  const ReviewDialog({super.key, required this.targets, this.listSettings});
  final List<ReviewTarget> targets;

  /// 「確認リストを見る」で開く確認リストに付ける印（tab_bar.dart の aboveNote）
  final RouteSettings? listSettings;

  @override
  State<ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<ReviewDialog> {
  /// 書き起こしを直すと差分が作り直されるので、いつも最新の状態から引く
  Utterance _uOf(ReviewTarget t) => t.c.state!.utterance(t.utteranceId);

  /// 言われたことの文面はどのノートでも同じなので、1冊目のものを見せる
  Utterance get _u => _uOf(widget.targets.first);

  // 発言者は AI がノートごとに読み取るので、読み取れなかったノートがあっても、読み取れた名前を出す
  late final _speaker =
      TextEditingController(text: [for (final t in widget.targets) ?_uOf(t).speaker].firstOrNull ?? '');
  late String _saidAt = _u.saidAt;
  final _editing = <String, TextEditingController>{};
  var _busy = false;

  /// 書き起こしを直している間の入力欄
  TextEditingController? _fix;

  bool get _hasSpeaker => _speaker.text.trim().isNotEmpty;

  /// 反映・確定したものは本文や確認の記録に残っているので、書き起こし・発言者・日付は直させない（ADR 0018）
  bool get _fixable => widget.targets.every((t) {
        final s = t.c.state!;
        return s.patchesOf(t.utteranceId).every((p) => p.status != 'applied') &&
            s.checks.where((c) => c.utteranceId == t.utteranceId).every((c) => c.resolution == null);
      });

  /// ノートを共有している人（持ち主と共有された人。自分は除く）。まだ何も言っていなくても候補に出す（ADR 0016）
  var _members = const <Person>[];

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  /// 読めなくても、言ったことのある人だけを候補にして続ける
  Future<void> _loadMembers() async {
    final lists = await Future.wait([
      for (final t in widget.targets) t.c.api.shares(t.c.manualId).catchError((Object _) => const <Person>[]),
    ]);
    final people = <String, Person>{
      for (final (i, t) in widget.targets.indexed)
        for (final p in [?t.c.state!.sharedBy, ...lists[i]])
          if (p.id != t.c.state!.me) p.id: p,
    };
    if (mounted) setState(() => _members = people.values.toList());
  }

  /// 発言者の候補。ノートを共有している人を先に、そのあとにこれらのノートで言ったことのある人を最近の順に。
  /// 欄に打った言葉があれば、名前かログイン ID にその言葉を含む人に絞り、ID で当たった人には ID を添える
  List<({String name, String? id})> get _knownSpeakers {
    final recent = [
      for (final t in widget.targets) ...t.c.state!.utterances.where((u) => u.id != t.utteranceId),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final all = <String, String?>{};
    for (final p in _members) {
      all.putIfAbsent(p.name, () => p.id);
    }
    for (final u in recent) {
      if (u.speaker case final name?) all.putIfAbsent(name, () => null);
    }
    final typed = _speaker.text.trim();
    final q = typed.toLowerCase();
    // 記録の発言者が入ったままのときや、候補をそのまま選んだときは絞らない
    if (q.isEmpty || typed == (_u.speaker ?? '') || all.containsKey(typed)) {
      return [for (final name in all.keys.take(_maxSpeakers)) (name: name, id: null)];
    }
    return [
      for (final MapEntry(key: name, value: id) in all.entries)
        if (name.toLowerCase().contains(q)) (name: name, id: null)
        else if (id != null && id.toLowerCase().contains(q)) (name: name, id: id),
    ].take(_maxSpeakers).toList();
  }

  /// 直した書き起こしで差分を作り直す。発言者と日付は、ここで変えたものだけを送り、ほかは読み直した結果に任せる
  Future<void> _fixText() async {
    final text = _fix!.text.trim();
    if (text.isEmpty) return;
    final before = _u;
    final speaker = _speaker.text.trim();
    final speakerKept = speaker == (before.speaker ?? '');
    final dayKept = _saidAt == before.saidAt;
    setState(() => _busy = true);
    try {
      await Future.wait([
        for (final t in widget.targets)
          t.c.editUtterance(
            t.utteranceId,
            text: text,
            speaker: speakerKept || speaker.isEmpty ? null : speaker,
            saidAt: dayKept ? null : _saidAt,
          ),
      ]);
      if (!mounted) return;
      setState(() {
        if (speakerKept) _speaker.text = _u.speaker ?? '';
        if (dayKept) _saidAt = _u.saidAt;
        _fix = null;
        _editing.clear();
      });
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 発言者と日付の変更を先に保存する。反映や確認はこの2つが揃っている前提
  Future<void> _saveMeta() async {
    final speaker = _speaker.text.trim();
    await Future.wait([
      for (final t in widget.targets)
        if (speaker != (_uOf(t).speaker ?? '') || _saidAt != _uOf(t).saidAt)
          t.c.editUtterance(t.utteranceId, speaker: speaker.isEmpty ? null : speaker, saidAt: _saidAt),
    ]);
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

  /// 閉じる前に発言者と日付を保存する。保存に失敗しても閉じられなくならないよう、エラーを出してから閉じる
  Future<void> _close() async {
    setState(() => _busy = true);
    try {
      await _saveMeta();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) Navigator.pop(context);
  }

  // Moon に日付選択が無いので、ここだけ Material の showDatePicker を使う（.claude/rules/flutter-ui.md）
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
    final k = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([for (final t in widget.targets) t.c]),
      builder: (context, _) {
        return Padding(
          padding: EdgeInsets.all(k.space.lg),
          child: MoonModal(
            backgroundColor: k.colors.canvas,
            // Moon の入力欄は Material の祖先を要求する
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: k.modalWidth),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.sm, 0),
                    child: Row(children: [
                      Expanded(child: Text('ノートに書き込む前の確認', style: k.text.title)),
                      MoonButton.icon(
                        semanticLabel: '閉じる',
                        icon: Icon(LucideIcons.x, color: k.colors.ink),
                        onTap: _busy ? null : _close,
                      ),
                    ]),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(k.space.xl, k.space.sm, k.space.xl, k.space.xl),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        ..._said(),
                        SizedBox(height: k.space.lg),
                        // 書き込んだ・確定した記録は証拠なので、発言者と日付も直させない（ADR 0018）
                        if (!_fixable)
                          Speaker(name: _u.speaker, day: _u.saidAt)
                        else ...[
                        Text('誰が言った？', style: k.text.small),
                        SizedBox(height: k.space.xs),
                        MoonTextInput(
                          controller: _speaker,
                          onChanged: (_) => setState(() {}),
                          errorText: _hasSpeaker ? null : '反映する前に入れてください',
                        ),
                        if (_knownSpeakers case final known when known.isNotEmpty) ...[
                          SizedBox(height: k.space.xs),
                          Wrap(spacing: k.space.xs, runSpacing: k.space.xs, children: [
                            for (final (:name, :id) in known)
                              MoonChip(
                                chipSize: MoonChipSize.sm,
                                isActive: _speaker.text.trim() == name,
                                semanticLabel: '発言者を$nameにする',
                                label: Text(id == null ? name : '$name（$id）'),
                                onTap: () => setState(() => _speaker.text = name),
                              ),
                          ]),
                        ],
                        SizedBox(height: k.space.sm),
                        MoonOutlinedButton(
                          onTap: _pickDate,
                          leading: const Icon(LucideIcons.calendar),
                          label: Text('${fmtDay(_saidAt)} に言われた'),
                        ),
                        ],
                        for (final t in widget.targets) ..._note(t),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 1冊のノートで変わる行。どのノートの話かを題名で示す
  List<Widget> _note(ReviewTarget t) {
    final k = context.tokens;
    final s = t.c.state!;
    final patches = s.patchesOf(t.utteranceId);
    return [
      SizedBox(height: k.space.xl),
      Text(s.title, style: k.text.label),
      SizedBox(height: k.space.sm),
      if (patches.isEmpty) ...[
        const Rule(),
        SizedBox(height: k.space.lg),
        Text('ノートに関わる内容は見つかりませんでした。発言の記録だけ残しています。', style: k.text.body),
      ],
      for (final p in patches) ...[
        const Rule(),
        SizedBox(height: k.space.lg),
        _patch(t.c, p),
        SizedBox(height: k.space.lg),
      ],
    ];
  }

  /// 言われたこと（書き起こし）。聞き間違いがあれば、ここで直して差分を作り直せる
  List<Widget> _said() {
    final k = context.tokens;
    final fix = _fix;
    if (fix == null) {
      return [
        StickyNote(child: Text('「${_u.text}」', style: k.text.body)),
        if (_fixable) ...[
          SizedBox(height: k.space.xs),
          MoonTextButton(
            onTap: _busy ? null : () => setState(() => _fix = TextEditingController(text: _u.text)),
            label: const Text('言われたことを直す'),
          ),
        ],
      ];
    }
    return [
      MoonTextInput(controller: fix, maxLines: 4, minLines: 1, hintText: '言われたこと'),
      SizedBox(height: k.space.sm),
      Row(children: [
        MoonTextButton(onTap: _busy ? null : () => setState(() => _fix = null), label: const Text('やめる')),
        const Spacer(),
        MoonFilledButton(
          onTap: _busy ? null : _fixText,
          leading: _busy ? const ButtonLoader() : null,
          label: const Text('直して照らし合わせ直す'),
        ),
      ]),
    ];
  }

  Widget _patch(ManualController c, Patch p) {
    final k = context.tokens;
    final chk = c.state!.checkOf(p.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        if (chk != null) ...[KindTag(chk.kind), SizedBox(width: k.space.sm)],
        Expanded(child: Text(p.summary, style: k.text.heading)),
      ]),
      if (chk != null) ...[
        SizedBox(height: k.space.xs),
        Text(chk.reason, style: k.text.small),
      ],
      SizedBox(height: k.space.md),
      if (chk?.kind == Kind.contradiction)
        ..._contradiction(c, p, chk!)
      else if (chk?.kind == Kind.same)
        ..._same(c, p, chk!)
      else
        ..._approvable(c, p),
    ]);
  }

  List<Widget> _contradiction(ManualController c, Patch p, Check chk) {
    final k = context.tokens;
    return [
      ConflictPair(
        leftLabel: 'ノート',
        left: chk.conflictLine ?? '',
        rightLabel: '${_hasSpeaker ? _speaker.text.trim() : '発言者未入力'}（${fmtDay(_saidAt)}）',
        right: p.text,
        settled: chk.resolution != null,
      ),
      SizedBox(height: k.space.md),
      if (chk.resolution != null)
        Text('${fmtDay(chk.resolution!.decidedAt)} ${chk.resolution!.decidedBy}${chk.resolution!.verb}して確定済み',
            style: k.text.body.copyWith(color: k.colors.added))
      else ...[
        // 記録した時点では解決を求めない。確認リストに入ったことだけを伝える
        Text('確認リストに入れました。聞けるときに確認して、決まったら記録します', style: k.text.body),
        SizedBox(height: k.space.md),
        Align(
          alignment: Alignment.centerLeft,
          child: MoonOutlinedButton(
            onTap: _busy
                ? null
                : () => _run(() async {
                      if (!mounted) return;
                      final nav = Navigator.of(context);
                      nav.pop();
                      await nav.push(MaterialPageRoute(
                          settings: widget.listSettings, builder: (_) => CheckListScreen(c: c)));
                    }),
            label: const Text('確認リストを見る'),
          ),
        ),
      ],
    ];
  }

  // 本文は変えないのが既定。判定が外れていたときのために反映もできるようにしておく
  List<Widget> _same(ManualController c, Patch p, Check chk) {
    final k = context.tokens;
    return [
      Text('ノートの「${plain(chk.sameLine ?? '')}」と同じ内容です。本文は変えずに、言われた記録として残します', style: k.text.body),
      SizedBox(height: k.space.sm),
      if (p.status != 'proposed')
        Text(p.status == 'applied' ? '反映済み' : '記録だけ残しました', style: k.text.small)
      else
        _buttons([
          MoonTextButton(
            onTap: _busy || !_hasSpeaker ? null : () => _run(() => c.applyPatch(p.id)),
            label: const Text('それでも書き込む'),
          ),
        ], MoonFilledButton(
            onTap: _busy ? null : () => _run(() => c.discardPatch(p.id)),
            leading: _busy ? const ButtonLoader() : null,
            label: const Text('書き込まない'),
          )),
    ];
  }

  /// 控えめな操作を左、主ボタンを右に置く。スマホの幅で1行に収まらなければ、主ボタンを次の行に送る
  Widget _buttons(List<Widget> secondary, Widget primary) {
    final k = context.tokens;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: k.space.xs,
      children: [Row(mainAxisSize: MainAxisSize.min, children: secondary), primary],
    );
  }

  List<Widget> _approvable(ManualController c, Patch p) {
    final k = context.tokens;
    final edit = _editing[p.id];
    return [
      if (edit == null)
        PatchDiff(op: p.op, line: p.line, text: p.text)
      else
        MoonTextInput(controller: edit, maxLines: 4, minLines: 1, hintText: '反映する内容を修正'),
      SizedBox(height: k.space.sm),
      if (p.status != 'proposed')
        Text(p.status == 'applied' ? '反映済み' : '反映しない', style: k.text.small)
      else
        _buttons([
          MoonTextButton(
            onTap: _busy ? null : () => _run(() => c.discardPatch(p.id)),
            label: const Text('書き込まない'),
          ),
          MoonTextButton(
            onTap: () => setState(() {
              if (edit == null) {
                _editing[p.id] = TextEditingController(text: p.text);
              } else {
                _editing.remove(p.id);
              }
            }),
            label: Text(edit == null ? '書き込む内容を直す' : 'やめる'),
          ),
        ], MoonFilledButton(
          onTap: _busy || !_hasSpeaker ? null : () => _run(() => c.applyPatch(p.id, text: edit?.text.trim())),
          leading: _busy ? const ButtonLoader() : null,
          label: const Text('ノートに書き込む'),
        )),
    ];
  }
}
