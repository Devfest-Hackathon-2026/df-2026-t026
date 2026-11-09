import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'history_screen.dart';
import 'review_dialog.dart';
import 'sidebar.dart';
import 'tab_bar.dart';

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

  /// 狭い画面で開いているタブ（0: 本文、1: 発言）
  var _tab = 0;

  /// 直接編集している所。at の行を書き換えるか、insert なら at の行の後ろ（null なら末尾）に足す
  ({int? at, bool insert})? _editing;
  final _draft = TextEditingController();
  var _saving = false;

  /// 食い違いを確かめている編集（パッチの ID）
  final _checking = <String>{};

  @override
  void dispose() {
    c.dispose();
    _draft.dispose();
    super.dispose();
  }

  void _startEdit(ManualState s, int? at, {required bool insert}) => setState(() {
        _editing = (at: at, insert: insert);
        _draft.text = insert ? '' : s.lines[at!].text;
      });

  void _cancelEdit() => setState(() => _editing = null);

  Future<void> _save(ManualState s, {bool delete = false}) async {
    final e = _editing!;
    final line = e.at == null ? null : s.lines[e.at!].text;
    // 行頭の空白はマークダウンの入れ子なので残す
    final text = delete ? '' : _draft.text.trimRight();
    if (!delete && text.trim().isEmpty) return;
    if (!e.insert && !delete && text == line) {
      _cancelEdit();
      return;
    }
    setState(() => _saving = true);
    try {
      final p = await c.edit(delete ? 'delete' : (e.insert ? 'insert' : 'replace'), line: line, text: text);
      setState(() => _editing = null);
      // 見出しと区切り線は主張ではないので確かめない
      if (!delete && !isHeading(text) && !isRule(text)) _check(p);
    } on ApiException catch (err) {
      if (mounted) showError(context, err);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 書いた行を先に出し、食い違いは後から確かめる（Gemini の待ちで編集を止めない）
  Future<void> _check(Patch p) async {
    setState(() => _checking.add(p.id));
    try {
      final chk = await c.checkEdit(p.id);
      if (chk != null && mounted) {
        showToast(context, '「${plain(chk.conflictLine!)}」と食い違っています。確認リストに入れました');
      }
    } on ApiException catch (err) {
      if (mounted) showError(context, '食い違いを確かめられませんでした：$err');
    } finally {
      if (mounted) setState(() => _checking.remove(p.id));
    }
  }

  void _openCheck(Check check) =>
      openCheckViaList(Navigator.of(context), c, check.id, settings: aboveNote(context, fromNote: true));

  // 狭い画面（サイドバーが出ない幅）では、キーボードでタブバーが隠れている間も、下のタブバーと同じ移り方にする。
  // 広い画面でも「ノートの上」の印を付けておき、狭い幅に変わっても「ノート」タブで1枚のノートに戻れるようにする
  void _openList() => _open(NoteTab.checks, CheckListScreen(c: c));

  void _openHistory() => _open(NoteTab.history, HistoryScreen(c: c));

  void _open(NoteTab tab, Widget screen) => showsSidebar(context)
      ? Navigator.push(context, MaterialPageRoute(settings: aboveNote(context, fromNote: true), builder: (_) => screen))
      : openNoteTab(context, c, from: NoteTab.note, to: tab);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        final open = s?.openChecks.length ?? 0;
        // 狭い画面では下のタブバーから移るので、上部バーには出さない（キーボードでタブバーが隠れている間も出さない）
        final narrow = s != null && !showsSidebar(context);
        return Scaffold(
          extendBody: true,
          bottomNavigationBar: narrow && showsNoteTabBar(context) ? NoteTabBar(c: c, current: NoteTab.note) : null,
          body: WithSidebar(api: widget.api, manualId: widget.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(
              crumbs: ['DiffNote（仮）', s?.title ?? ''],
              trailing: s == null || narrow
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      MoonOutlinedButton(
                        buttonSize: MoonButtonSize.sm,
                        onTap: _openHistory,
                        label: const Text('履歴'),
                      ),
                      SizedBox(width: context.tokens.space.sm),
                      MoonOutlinedButton(
                        buttonSize: MoonButtonSize.sm,
                        onTap: _openList,
                        label: Text(open == 0 ? '確認リスト' : '確認リスト $open'),
                      ),
                    ]),
            ),
            Expanded(
              child: s == null
                  ? (c.loadError != null ? LoadFailed(message: c.loadError!, onRetry: c.load) : const Loading())
                  : LayoutBuilder(builder: (context, box) => _layout(s, box.maxWidth)),
            ),
          ]))),
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
        SizedBox(width: k.panelWidth, child: _utterances(s, withHeader: true)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // 方眼がタブの文字の後ろに出ないよう、白い帯に載せる
      Container(
        decoration: BoxDecoration(
          color: k.colors.canvas,
          border: Border(bottom: BorderSide(color: k.colors.rule, width: k.hairline)),
        ),
        padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.sm),
        child: MoonTabBar(
          tabBarSize: MoonTabBarSize.sm,
          initialIndex: _tab,
          onTabChanged: (i) => setState(() => _tab = i),
          tabs: [
            // 下のタブバーの「ノート」とぶつからないよう「本文」と呼ぶ
            const MoonTab(label: Text('本文')),
            MoonTab(label: Text('発言 ${s.said.length}')),
          ],
        ),
      ),
      Expanded(child: _tab == 0 ? _document(s) : _utterances(s, withHeader: false)),
    ]);
  }

  /// 文書面：題名・メタ情報・本文。白い面に載せる
  Widget _document(ManualState s) {
    final k = context.tokens;
    final changed = s.lines.where((l) => l.patchId != null && !_fromEdit(s, l)).length;
    return Builder(builder: (context) => SingleChildScrollView(
      padding: belowTabBar(context, EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.xxl)),
      child: Narrow(
        child: PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xxl, k.space.xl, k.space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.only(left: k.gutter),
              child: PageTitle(s.title, meta: [
                Text('記録 ${s.said.length} 件', style: k.text.small),
                Text('口頭で変わった行 $changed 行', style: k.text.small),
                if (s.openChecks.isNotEmpty)
                  StatusTag('あとで確認 ${s.openChecks.length} 件',
                      bg: k.colors.pendingBg, fg: k.colors.pending, onTap: _openList),
              ]),
            ),
            SizedBox(height: k.space.xl),
            if (s.lines.isEmpty && _editing == null)
              Padding(
                padding: EdgeInsets.only(left: k.gutter, bottom: k.space.md),
                child: Text('まだ白紙です。ここに直接書くか、入力ページで教わったことを記録すると書き足されます。', style: k.text.small),
              ),
            for (final (i, line) in s.lines.indexed) ...[
              if (_editing == (at: i, insert: false)) _editor(s) else _line(s, line, i),
              if (_editing == (at: i, insert: true)) _editor(s),
            ],
            if (_editing == (at: null, insert: true))
              _editor(s)
            else
              Padding(
                padding: EdgeInsets.only(left: k.gutter, top: k.space.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MoonTextButton(
                    buttonSize: MoonButtonSize.sm,
                    onTap: () => _startEdit(s, null, insert: true),
                    label: const Text('行を足す'),
                  ),
                ),
              ),
          ]),
        ),
      ),
    ));
  }

  bool _fromEdit(ManualState s, ManualLine line) =>
      line.patchId != null && s.utterance(s.patch(line.patchId!).utteranceId).fromEdit;

  /// 直接編集の欄。行の場所に開く
  Widget _editor(ManualState s) {
    final k = context.tokens;
    final e = _editing!;
    return Padding(
      padding: EdgeInsets.fromLTRB(k.gutter, k.space.xs, 0, k.space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MoonTextInput(
          controller: _draft,
          autofocus: true,
          hintText: '例: - 塩 小さじ1（マークダウンで書けます。見出しは「## 」で始める）',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(s),
        ),
        SizedBox(height: k.space.sm),
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, children: [
          MoonFilledButton(
            buttonSize: MoonButtonSize.sm,
            onTap: _saving || _draft.text.trim().isEmpty ? null : () => _save(s),
            leading: _saving ? const ButtonLoader() : null,
            label: const Text('保存する'),
          ),
          if (!e.insert) ...[
            MoonOutlinedButton(
              buttonSize: MoonButtonSize.sm,
              onTap: _saving ? null : () => _save(s, delete: true),
              label: const Text('この行を消す'),
            ),
            MoonTextButton(
              buttonSize: MoonButtonSize.sm,
              onTap: _saving ? null : () => _startEdit(s, e.at, insert: true),
              label: const Text('下に行を足す'),
            ),
          ],
          MoonTextButton(buttonSize: MoonButtonSize.sm, onTap: _saving ? null : _cancelEdit, label: const Text('やめる')),
        ]),
      ]),
    );
  }

  /// 押すとその場で直接編集を開く
  Widget _editable(ManualState s, int i, Widget child) => MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _startEdit(s, i, insert: false),
          child: child,
        ),
      );

  Widget _line(ManualState s, ManualLine line, int i) {
    final k = context.tokens;
    if (line.text.trim().isEmpty) return SizedBox(height: k.space.sm);
    if (isHeading(line.text)) {
      return _editable(
        s,
        i,
        Padding(
          padding: EdgeInsets.fromLTRB(k.gutter, k.space.xl, 0, k.space.xs),
          child: LineText(line.text),
        ),
      );
    }
    final open = s.openChecksFor(line);
    final confirmed = s.confirmationFor(line);
    final patch = line.patchId == null ? null : s.patch(line.patchId!);
    final said = patch == null ? null : s.utterance(patch.utteranceId);
    // 左余白の色線は変更の種類を表す：あとで確認は黄、口頭で変わった行は緑。食い違いでも行の地は塗らない。
    // 直接書いた行は本人の文なので、色線も発言者も付けない
    final oral = said != null && !said.fromEdit;
    final bar = open.isNotEmpty ? k.colors.pending : (oral || confirmed != null ? k.colors.added : null);
    final marks = <Widget>[
      // 確認して決めた行は、小さい確認印でなく、誰に確認したかを発言者と同じ形で見せる。押すと確認の記録を開く
      if (confirmed != null)
        Wrap(spacing: k.space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Speaker(
            name: confirmed.resolution!.decidedBy,
            day: confirmed.resolution!.decidedAt,
            onTap: () => _openCheck(confirmed),
          ),
          Text('に確認', style: k.text.small),
        ])
      else if (oral)
        Speaker(name: said.speaker, day: said.saidAt, onTap: () => _showUtterance(said)),
      if (patch != null && _checking.contains(patch.id)) Text('食い違いがないか確かめています', style: k.text.small),
      for (final c in s.sameChecksFor(line))
        Wrap(spacing: k.space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Speaker(
            name: s.utterance(c.utteranceId).speaker,
            day: s.utterance(c.utteranceId).saidAt,
            onTap: () => _showUtterance(s.utterance(c.utteranceId)),
          ),
          Text('も同じ', style: k.text.small),
        ]),
      // 食い違っていることをその場で見せる：「マニュアルの行 ／ 誰（日付）：言われたこと」
      for (final o in open)
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('／', style: k.text.body.copyWith(color: k.colors.pending)),
          Text('${s.utterance(o.utteranceId).speaker ?? '発言者未入力'}（${fmtDay(s.utterance(o.utteranceId).saidAt)}）：',
              style: k.text.small),
          Text(plain(s.patch(o.patchId).text), style: k.text.body),
          StatusTag('食い違い', bg: k.colors.pendingBg, fg: k.colors.pending),
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
    if (open.isEmpty) return _editable(s, i, row);
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
              Text('「${u.text}」', style: k.text.body),
              SizedBox(height: k.space.xl),
              MoonOutlinedButton(label: const Text('閉じる'), onTap: () => Navigator.pop(ctx)),
            ]),
          ),
        ),
      ),
    );
  }

  /// 記録した発言のパネル。withHeader が false なら一覧だけ（狭い画面のタブの中身）
  Widget _utterances(ManualState s, {required bool withHeader}) {
    final k = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (withHeader)
        Padding(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.md),
          child: Text('記録した発言（${s.said.length}）', style: k.text.title),
        ),
      Expanded(
        child: s.said.isEmpty
            ? Padding(
                padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
                child: Text('入力ページで記録すると、ここに付箋で並びます', style: k.text.small),
              )
            : Builder(builder: (context) => ListView(
                padding: belowTabBar(context, EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg)),
                children: [
                  for (final u in s.said.reversed) ...[
                    _utteranceEntry(s, u),
                    SizedBox(height: k.space.lg),
                  ],
                ],
              )),
      ),
    ]);
  }

  /// 発言：誰が・いつ → 言われたこと → 状態。付箋で見せる
  Widget _utteranceEntry(ManualState s, Utterance u) {
    final k = context.tokens;
    return StickyNote(
      onTap: () => showReview(context, c, u.id),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Speaker(name: u.speaker, day: u.saidAt),
        SizedBox(height: k.space.sm),
        Text(u.text, style: k.text.body),
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
    return StatusTag(status, bg: bg, fg: fg);
  }

  List<String> _statuses(ManualState s, Utterance u) {
    if (s.resolvedChecks.any((c) => c.resolution!.utteranceId == u.id)) return ['確認の答え'];
    final patches = s.patchesOf(u.id);
    if (patches.isEmpty) return ['差分なし'];
    return patches.map((p) {
      final chk = s.checkOf(p.id);
      if (chk?.resolution != null) return '確認済み';
      if (chk?.isOpen ?? false) return 'あとで確認';
      if (chk?.kind == Kind.same && p.status == 'discarded') return '同じ内容';
      return switch (p.status) { 'applied' => '反映済み', 'discarded' => '反映しない', _ => '未反映' };
    }).toList();
  }
}
