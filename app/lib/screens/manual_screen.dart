import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'materials_screen.dart';
import 'review_dialog.dart';
import 'share_dialog.dart';
import 'sidebar.dart';
import 'tab_bar.dart';

/// マニュアル1冊の画面：文書面（現行マニュアル）と、記録した発言のパネル。食い違いは確認リスト（別の画面）にまとめる
class ManualScreen extends StatefulWidget {
  const ManualScreen({super.key, required this.api, required this.manualId, this.found});
  final Api api;
  final String manualId;

  /// 「ノートを探す」から開いたときの、押した行の番号と探した言葉。その行まで送り、言葉に地を付ける
  final ({int line, String query})? found;

  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  /// 上部バーの「…」（その他）のメニューを開いているか
  var _more = false;

  late final c = ManualController(widget.api, widget.manualId)..load();

  /// 狭い画面で開いているタブ（0: 本文、1: 発言）
  var _tab = 0;

  /// 直接編集している所。at の行を書き換えるか、insert なら at の行の後ろ（null なら末尾）に足す
  ({int? at, bool insert})? _editing;
  final _draft = TextEditingController();
  final _focus = FocusNode();

  /// 編集欄。Enter で次の行へ移っても同じ欄のままにし、打っている所（フォーカス）を外さない
  final _editorKey = GlobalKey();

  /// 食い違いを確かめている編集と、確かめを待っている編集（パッチの ID）
  final _checking = <String>{};

  /// 探して開いた行。開いて最初に読めたときに1度だけ、その行まで送る
  final _foundKey = GlobalKey();
  late var _toFound = widget.found != null;

  @override
  void initState() {
    super.initState();
    c.onEditFailed = _editFailed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ほかの画面やダイアログ（確認リスト・履歴・資料・共有・発言・下のタブバー・サイドバー）が上に開いたら、欄を閉じる。
    // 欄を開いている間は編集の応答を画面に入れないので、開いたままだとほかの画面に最新の状態が出ない
    if (ModalRoute.isCurrentOf(context) == false && _editing != null) {
      _editing = null;
      // 閉じると取っておいた応答が入り、ほかの画面も描き直すので、描いている最中には知らせない
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editing == null) c.editorOpen = false;
      });
    }
  }

  @override
  void dispose() {
    c.onEditFailed = null;
    c.dispose();
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 欄を開く・動かす・閉じる。text を渡せば欄の文面にする
  void _setEditing(({int? at, bool insert})? e, {String? text}) {
    setState(() {
      _editing = e;
      if (text != null) _draft.text = text;
    });
    c.editorOpen = e != null;
    if (e != null) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  /// at は描いたときの行の番号。store の最新は、欄を開いたことにしてから読み、土台に入れない。
  /// 先に読むと、同じ描画の間に届いた状態が入って行がずれ、押した行と違う行の欄が開く
  void _startEdit(int? at, {required bool insert}) {
    c.editorOpen = true;
    _setEditing((at: at, insert: insert), text: insert ? '' : c.state!.lines[at!].text);
  }

  void _close() => _setEditing(null);

  /// 欄の外を押して閉じる。押した先が別の行なら、このあとその行が欄を開き直す。閉じたその場で取っておいた状態を
  /// 土台に入れると、行がずれて押した行と違う行を開くので、入れるのは描き終えてから、開き直していなければにする
  void _closeOutside() {
    setState(() => _editing = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing == null) c.editorOpen = false;
    });
  }

  /// 書いた行を先に出し、送信は裏で順に送る。next（Enter）なら、メモ帳のように続けて書けるよう、
  /// 書いた行のすぐ下に次の行の欄を開く。空のまま Enter を押したら閉じる
  void _save({bool delete = false, bool next = false}) {
    final s = c.state!;
    final e = _editing!;
    final line = e.at == null ? null : s.lines[e.at!].text;
    // 行頭の空白はマークダウンの入れ子なので残す
    final text = delete ? '' : _draft.text.trimRight();
    if (!delete && text.trim().isEmpty) return _close();
    if (!e.insert && !delete && text == line) {
      return next ? _setEditing((at: e.at, insert: true), text: '') : _close();
    }
    final edit = c.edit(delete ? 'delete' : (e.insert ? 'insert' : 'replace'), line: line, text: text);
    // 見出しと区切り線は主張ではないので確かめない
    final check = !delete && !isHeading(text) && !isRule(text);
    if (check) _checking.add(edit.patch.id);
    if (next) {
      // 同じ文の行が上にあると、足した行はそちらの下に入る（ADR 0001）ので、番号ではなく差分で探す
      final added = c.state!.lines.lastIndexWhere((l) => l.patchId == edit.patch.id);
      _setEditing(e.at == null || added < 0 ? (at: null, insert: true) : (at: added, insert: true), text: '');
    } else {
      _close();
    }
    _follow(edit, check: check);
  }

  /// 届いたら食い違いを確かめる。届かなかったときの知らせは _editFailed で出す
  Future<void> _follow(LocalEdit edit, {required bool check}) async {
    final saved = await edit.saved;
    if (saved && check) return _check(edit.patch.id);
    if (mounted) setState(() => _checking.remove(edit.patch.id));
  }

  /// 届かなかった編集を戻したとき。ほかの人が先に同じ行を直していたら選んでもらい、そうでなければ何行戻したかを知らせる
  void _editFailed(EditFailure f) {
    if (!mounted) return;
    final s = c.state!;
    final p = f.edit.patch;
    if (f.error case final EditConflict conflict) {
      _resolveConflict(conflict, p.op == 'delete' ? null : p.text);
      if (f.count > 1) showError(context, '続けて直した ${f.count - 1} 行は保存していません。書き直してください');
      return;
    }
    final failed = '保存できませんでした（${f.error}）。直した ${f.count} 行を元に戻しました';
    // ほかの画面（確認リスト・履歴・資料・ダイアログ）が上に開いていれば、欄を開かず知らせるだけにする。
    // 隠れた欄を開くと、閉じるまで store の状態が上の画面に入らず、上の画面で打った文字がその欄に入るおそれもある
    if (ModalRoute.isCurrentOf(context) != true) return showError(context, '$failed。書き直してください');
    if (_editing case final e?) {
      // 書いている欄の文面はそのまま。戻した行の分だけ番号がずれるので、同じ行に合わせ直す
      _setEditing(_remap(e, f.shown, s.lines));
      showError(context, '$failed。書き直してください');
      return;
    }
    // 消されたノートには書けないので、欄を開き直さない
    if (c.gone) return showError(context, failed);
    // 欄を閉じていれば、届かなかった行の文面をその場所の欄に入れ直す
    final at = p.line == null ? null : s.lines.indexWhere((l) => l.text == p.line);
    if (p.op == 'delete' || at == -1) return showError(context, '$failed。書き直してください');
    _setEditing((at: at, insert: p.op == 'insert'), text: p.text);
    showError(context, '$failed。書いた文は欄に残したので、もう一度保存してください');
  }

  /// 戻す前の行 from で開いていた欄の場所を、戻した後の行 to に合わせる。
  /// 欄の行が戻って無くなったら、その上に残っている行の下に足す欄にする（無ければ末尾）
  ({int? at, bool insert}) _remap(({int? at, bool insert}) e, List<ManualLine> from, List<ManualLine> to) {
    // サーバーから来た行は同じ物のまま残る。手元で当てた行は当て直して別の物になるので、差分と文で探す
    int find(ManualLine l) {
      final i = to.indexWhere((x) => identical(x, l));
      return i >= 0 || l.patchId == null ? i : to.indexWhere((x) => x.patchId == l.patchId && x.text == l.text);
    }

    final at = e.at;
    if (at == null) return e;
    final same = find(from[at]);
    if (same >= 0) return (at: same, insert: e.insert);
    for (var i = at - 1; i >= 0; i--) {
      final above = find(from[i]);
      if (above >= 0) return (at: above, insert: true);
    }
    return (at: null, insert: true);
  }

  /// ほかの人が先に同じ行を直していたら、どちらにするかを選んでもらう（ADR 0016）。mine は自分の直し（消すなら null）
  Future<void> _resolveConflict(EditConflict conflict, String? mine) async {
    // 欄の位置は今のノートの行の番号なので、読み直す前に閉じる
    _close();
    // 選んでいる間に、さらにほかの人が同じ行を直していたら、もう一度選んでもらう
    EditConflict? next = conflict;
    while (next != null && mounted) {
      final x = next!;
      next = null;
      // 相手と同じ直しなら、もう済んでいる
      if (x.theirs == mine) return c.load();
      final saved = await showMoonModal<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ConflictDialog(conflict: x, mine: mine, save: () async => next = await _saveMine(x, mine)),
      );
      if (saved != true) return c.load();
    }
  }

  /// 「自分のにする」：相手の直しの上に、自分の直しを新しい編集として送る。また先を越されたら、その衝突を返す。
  /// ダイアログの中なので、ここは応答を待ってから閉じる
  Future<EditConflict?> _saveMine(EditConflict conflict, String? mine) async {
    try {
      final id = switch ((mine, conflict.theirs)) {
        (null, final theirs) => await c.editAndWait('delete', line: theirs),
        (final text?, final theirs?) => await c.editAndWait('replace', line: theirs, text: text),
        (final text?, null) => await c.editAndWait('insert', line: conflict.after, text: text),
      };
      if (mine != null && !isHeading(mine) && !isRule(mine)) _check(id);
    } on EditConflict catch (again) {
      return again;
    } on ApiException catch (err) {
      if (mounted) showError(context, err);
      await c.load();
    }
    return null;
  }

  /// 書いた行を先に出し、食い違いは後から確かめる（Gemini の待ちで編集を止めない）
  Future<void> _check(String patchId) async {
    if (mounted) setState(() => _checking.add(patchId));
    try {
      final chk = await c.checkEdit(patchId);
      if (chk != null && mounted) {
        final where = chk.materialRef == null ? '' : '${chk.materialRef!.label} の';
        showToast(context, '$where「${plain(chk.conflictLine!)}」と食い違っています。確認リストに入れました');
      }
    } on ApiException catch (err) {
      if (mounted) showError(context, '食い違いを確かめられませんでした：$err');
    } finally {
      if (mounted) setState(() => _checking.remove(patchId));
    }
  }

  void _openCheck(Check check) =>
      openCheckViaList(Navigator.of(context), c, check.id, settings: aboveNote(context, fromNote: true));

  // 狭い画面（サイドバーが出ない幅）では、キーボードでタブバーが隠れている間も、下のタブバーと同じ移り方にする。
  // 広い画面でも「ノートの上」の印を付けておき、狭い幅に変わっても「ノート」タブで1枚のノートに戻れるようにする
  void _openList() => _open(NoteTab.checks, CheckListScreen(c: c));

  /// utteranceId を渡すと、その記録で作った版を選んで開く
  void _openHistory({String? utteranceId}) =>
      _open(NoteTab.history, HistoryScreen(c: c, utteranceId: utteranceId), utteranceId: utteranceId);

  /// 資料は下のタブバーに無いので、狭い画面でもノートの上に積み、戻る矢印で戻る（ADR 0019）
  void _openMaterials() => Navigator.push(
      context, MaterialPageRoute(settings: aboveNote(context, fromNote: true), builder: (_) => MaterialsScreen(c: c)));

  void _open(NoteTab tab, Widget screen, {String? utteranceId}) => showsSidebar(context)
      ? Navigator.push(context, MaterialPageRoute(settings: aboveNote(context, fromNote: true), builder: (_) => screen))
      : openNoteTab(context, c, from: NoteTab.note, to: tab, utteranceId: utteranceId);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        // 消された・共有を外されたノートは、古い内容を出さずに「見つかりません」を出す。書いている欄は閉じるまで残す
        final s = c.gone && _editing == null ? null : c.state;
        final open = s?.openChecks.length ?? 0;
        if (s != null && _toFound) {
          _toFound = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_foundKey.currentContext case final ctx?) Scrollable.ensureVisible(ctx, alignment: 0.3);
          });
        }
        // 狭い画面では下のタブバーから移るので、上部バーには出さない（キーボードでタブバーが隠れている間も出さない）
        final narrow = s != null && !showsSidebar(context);
        // 共有は共有された人もできる。タブバーに無いので、狭い画面でも上部バーに出す（ADR 0016）。ノートを消すのは持ち主だけ
        final mine = s != null && s.sharedBy == null;
        return Scaffold(
          extendBody: true,
          bottomNavigationBar: narrow && showsNoteTabBar(context) ? NoteTabBar(c: c, current: NoteTab.note) : null,
          body: WithSidebar(api: widget.api, manualId: widget.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(
              crumbs: [s?.title ?? ''],
              trailing: s == null
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      // 資料は共有された人も見て足せる。タブバーに無いので、狭い画面でも出す（ADR 0019）
                      MoonOutlinedButton(
                        buttonSize: MoonButtonSize.sm,
                        onTap: _openMaterials,
                        label: const Text('資料'),
                      ),
                      SizedBox(width: context.tokens.space.sm),
                      if (!narrow) ...[
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
                      ],
                      if (!narrow) SizedBox(width: context.tokens.space.sm),
                      MoonOutlinedButton(
                        buttonSize: MoonButtonSize.sm,
                        onTap: () => showShare(context, widget.api, widget.manualId, owner: s.sharedBy),
                        label: const Text('共有'),
                      ),
                      if (mine) ...[
                        SizedBox(width: context.tokens.space.xs),
                        _moreMenu(s),
                      ],
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
                if (s.sharedBy case final owner?) Text('${owner.name} から共有', style: k.text.small),
                Text('記録 ${s.said.length} 件', style: k.text.small),
                Text('口頭で変わった行 $changed 行', style: k.text.small),
                if (s.openChecks.isNotEmpty)
                  StatusTag('あとで確認 ${s.openChecks.length} 件',
                      bg: k.colors.pendingBg, fg: k.colors.pending, onTap: _openList),
                // 書いた行は先に出し、裏で送っている。届く前にタブを閉じると残らないので、送っている間だけ出す
                if (c.saving) Text('保存しています…', style: k.text.small),
              ]),
            ),
            SizedBox(height: k.space.xl),
            if (s.lines.isEmpty && _editing == null)
              Padding(
                padding: EdgeInsets.only(left: k.gutter, bottom: k.space.md),
                child: Text('まだ白紙です。ここに直接書くか、入力ページで教わったことを記録すると書き足されます。', style: k.text.small),
              ),
            for (final (i, line) in s.lines.indexed) ...[
              if (_editing == (at: i, insert: false))
                _editor()
              else if (i == _foundLine(s))
                KeyedSubtree(key: _foundKey, child: _line(s, line, i))
              else
                _line(s, line, i),
              if (_editing == (at: i, insert: true)) _editor(),
            ],
            if (_editing == (at: null, insert: true))
              _editor()
            else
              Padding(
                padding: EdgeInsets.only(left: k.gutter, top: k.space.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // 押せると分かるよう、枠のあるボタンにして＋を添える
                  child: MoonOutlinedButton(
                    buttonSize: MoonButtonSize.sm,
                    onTap: () => _startEdit(null, insert: true),
                    leading: Icon(LucideIcons.plus, size: k.buttonIconSm),
                    label: const Text('行を足す'),
                  ),
                ),
              ),
          ]),
        ),
      ),
    ));
  }

  /// 探して押した行。探した後に行がずれていたら、言葉を含む最初の行にする
  int? _foundLine(ManualState s) {
    final f = widget.found;
    if (f == null) return null;
    bool has(int i) => plain(s.lines[i].text).toLowerCase().contains(f.query.toLowerCase());
    if (f.line < s.lines.length && has(f.line)) return f.line;
    for (var i = 0; i < s.lines.length; i++) {
      if (has(i)) return i;
    }
    return null;
  }

  bool _fromEdit(ManualState s, ManualLine line) =>
      line.patchId != null && s.utterance(s.patch(line.patchId!).utteranceId).fromEdit;

  /// 直接編集の欄。行の場所に開く。右端のチェックで保存して閉じ、バツで行を消す（まだ無い行なら閉じる）。
  /// Enter で保存して下に次の行の欄を開き、空のまま Enter か Esc、欄の外を押すと閉じる
  Widget _editor() {
    final k = context.tokens;
    final e = _editing!;
    return TapOutside(
      key: _editorKey,
      onTapOutside: _closeOutside,
      child: Padding(
        padding: EdgeInsets.fromLTRB(k.gutter, k.space.xs, 0, k.space.sm),
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MoonTextInput(
              controller: _draft,
              focusNode: _focus,
              autofocus: true,
              hintText: '例: - 塩 小さじ1（マークダウンで書けます。見出しは「## 」で始める）',
              // 既定では Enter で打つ所が外れるので、外さずに次の行を続けて書けるようにする
              onEditingComplete: () {},
              onSubmitted: (_) => _save(next: true),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                // 打つたびにノート全体を作り直さないよう、欄の文で変わるチェックだけを作り直す
                ListenableBuilder(
                  listenable: _draft,
                  builder: (_, _) => MoonButton.icon(
                    buttonSize: MoonButtonSize.sm,
                    semanticLabel: '保存する',
                    onTap: _draft.text.trim().isEmpty ? null : _save,
                    icon: Icon(LucideIcons.check, color: k.colors.action),
                  ),
                ),
                MoonButton.icon(
                  buttonSize: MoonButtonSize.sm,
                  semanticLabel: 'この行を消す',
                  // まだ無い行は、閉じれば消えたのと同じ
                  onTap: e.insert ? _close : () => _save(delete: true),
                  icon: Icon(LucideIcons.x, color: k.colors.inkMuted),
                ),
              ]),
            ),
            if (!e.insert) ...[
              SizedBox(height: k.space.sm),
              MoonTextButton(
                buttonSize: MoonButtonSize.sm,
                onTap: () => _startEdit(e.at, insert: true),
                label: const Text('下に行を足す'),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// 押すとその場で直接編集を開く
  Widget _editable(ManualState s, int i, Widget child) => MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _startEdit(i, insert: false),
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
          child: LineText(line.text, mark: widget.found?.query),
        ),
      );
    }
    final open = s.openChecksFor(line);
    final confirmed = s.confirmationFor(line);
    final patch = line.patchId == null ? null : s.patch(line.patchId!);
    final said = patch == null ? null : s.utterance(patch.utteranceId);
    // 左余白の色線は変更の種類を表す：あとで確認は黄、口頭で変わった行は緑。食い違いでも行の地は塗らない。
    // 持ち主が直接書いた行は本人の文なので、色線も発言者も付けない。共有された人が直した行は、口頭と同じく誰が直したかを出す
    final byOther = said != null && (!said.fromEdit || said.editedBy != null);
    final bar = open.isNotEmpty ? k.colors.pending : (byOther || confirmed != null ? k.colors.added : null);
    // 確認したあとに補足で書き換わった行は、補足を言った人に加えて、もとの確認も見せる
    final afterQualification = confirmed != null && confirmed.resolution!.text != line.text;
    final marks = <Widget>[
      if (byOther && (confirmed == null || afterQualification))
        Speaker(name: said.speaker, day: said.saidAt, onTap: () => _showUtterance(said)),
      // 確認して決めた行は、小さい確認印でなく、誰に確認したかを発言者と同じ形で見せる。押すと確認の記録を開く
      // 「に確認」も Speaker の中に入れて、どこを押しても確認の記録を開く（下の行の書き換えの欄は開かない）
      if (confirmed != null)
        Speaker(
          name: confirmed.resolution!.decidedBy,
          day: confirmed.resolution!.decidedAt,
          after: confirmed.resolution!.verb,
          onTap: () => _openCheck(confirmed),
        ),
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
      // 食い違っていることをその場で見せる：「マニュアルの行 ／ 誰（日付）：言われたこと」。
      // 直接書いた行が資料と食い違ったときは、この行が言われた側なので、相手の資料の行を「／ 資料「…」p.3：…」で見せる
      for (final o in open)
        Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('／', style: k.text.body.copyWith(color: k.colors.pending)),
          Text(
              o.materialRef == null
                  ? '${s.utterance(o.utteranceId).speaker ?? '発言者未入力'}（${fmtDay(s.utterance(o.utteranceId).saidAt)}）：'
                  : '${o.materialRef!.label}：',
              style: k.text.small),
          Text(plain(o.materialRef == null ? s.patch(o.patchId).text : o.conflictLine ?? ''), style: k.text.body),
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
              children: [LineText(line.text, mark: widget.found?.query), ...marks],
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

  /// 上部バーの「…」（その他）。ボタンを増やしすぎないよう、まれにしか使わない操作をここにまとめる。持ち主だけに出す
  Widget _moreMenu(ManualState s) {
    final k = context.tokens;
    return MoonDropdown(
      show: _more,
      dropdownAnchorPosition: MoonDropdownAnchorPosition.bottomRight,
      backgroundColor: k.colors.canvas,
      borderColor: k.colors.rule,
      onTapOutside: () => setState(() => _more = false),
      // 既定では画面いっぱいまで広がるので、項目の幅に合わせる
      content: IntrinsicWidth(
        child: MoonMenuItem(
          borderRadius: k.radius.control,
          onTap: () {
            setState(() => _more = false);
            _confirmDelete(s);
          },
          // 飾りのアイコンは付けない（flutter-ui.md）。危ない操作なので文字を消した行と同じ赤にする
          label: Text('ノートを消す', style: k.text.body.copyWith(color: k.colors.removed)),
        ),
      ),
      child: MoonButton.icon(
        buttonSize: MoonButtonSize.sm,
        semanticLabel: 'その他',
        backgroundColor: _more ? k.colors.shell : null,
        onTap: () => setState(() => _more = !_more),
        icon: Icon(LucideIcons.ellipsis, color: k.colors.ink),
      ),
    );
  }

  /// 消す前に必ず確かめる（元に戻せない。ADR 0014）。消せたら、このノートとその上の画面を外してノート一覧へ
  Future<void> _confirmDelete(ManualState s) async {
    final nav = Navigator.of(context);
    final note = ModalRoute.of(context);
    final deleted = await showMoonModal<bool>(
      context: context,
      // 消している間に外を押して閉じると、消えたノートの画面に取り残される。閉じるのは「やめる」だけ
      barrierDismissible: false,
      builder: (_) => _DeleteDialog(api: widget.api, manualId: widget.manualId, title: s.title),
    );
    if (deleted != true || !mounted) return;
    // どこから開いていても（サイドバー・一覧・入力ページ・共有された一覧）、ノートとその上（確認リスト・履歴）を外して一覧を開く。
    // 一覧は最初の画面（入力ページ）の上に1枚だけ置き、戻ると入力ページに出る（サイドバーから開いたときと同じ積み方）。
    // 広い画面はサイドバーと同じく動きを付けない
    final wide = showsSidebar(context);
    final Route<void> home = wide
        ? PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => HomeScreen(api: widget.api),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          )
        : MaterialPageRoute<void>(builder: (_) => HomeScreen(api: widget.api));
    if (note?.isFirst ?? false) {
      nav.pushAndRemoveUntil(home, (_) => false);
    } else {
      nav.pushAndRemoveUntil(home, (r) => r.isFirst);
    }
    // このノートの画面は外れるので、知らせは Navigator の上に出す
    showToast(nav.context, 'ノートを消しました');
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
              if (recordedByText(u) case final by?) ...[SizedBox(height: k.space.sm), Text(by, style: k.text.small)],
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
    // 共有した相手が行を直した記録も、細い札で時刻の順に混ぜる。持ち主の直しは本人の文なので出さない（ADR 0020）
    final said = s.said.toSet();
    final entries = s.utterances.where((u) => said.contains(u) || (u.fromEdit && u.editedBy != null)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (withHeader)
        Padding(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.md),
          child: Text('記録した発言（${s.said.length}）', style: k.text.title),
        ),
      Expanded(
        child: entries.isEmpty
            ? Padding(
                padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
                child: Text('入力ページで記録すると、ここに付箋で並びます', style: k.text.small),
              )
            // 記録が多くても、見えている分だけ作る。新しい記録を上にする
            : Builder(builder: (context) => ListView.builder(
                padding: belowTabBar(context, EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.lg)),
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final u = entries[entries.length - 1 - i];
                  return Padding(
                    padding: EdgeInsets.only(bottom: k.space.lg),
                    child: u.fromEdit ? _editEntry(s, u) : _utteranceEntry(s, u),
                  );
                },
              )),
      ),
    ]);
  }

  /// 発言：誰が・いつ → 言われたこと → 状態。付箋で見せる
  Widget _utteranceEntry(ManualState s, Utterance u) {
    final k = context.tokens;
    return StickyNote(
      // 書き込む前の確認は、記録した本人だけ。ほかの人には言われたことと記録した人を見せる（ADR 0018）
      onTap: () => s.recordedByMe(u) ? showReview(context, [(c: c, utteranceId: u.id)]) : _showUtterance(u),
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

  /// 共有した相手が行を直した記録。付箋より細い白い札にし、押すと履歴でその版を開く（ADR 0020）
  Widget _editEntry(ManualState s, Utterance u) {
    final k = context.tokens;
    final p = s.patchesOf(u.id).firstOrNull;
    return MoonMenuItem(
      onTap: () => _openHistory(utteranceId: u.id),
      backgroundColor: k.colors.canvas,
      borderRadius: k.radius.paper,
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.sm),
      label: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Speaker(name: u.speaker, day: u.saidAt, after: 'が行を直した'),
        SizedBox(height: k.space.xs),
        Text(p == null ? u.text : editSummary(p.op, p.line, p.text),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: k.text.small),
      ]),
      trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
    );
  }

  Widget _statusTag(String status) {
    final c = context.tokens.colors;
    final (bg, fg) = switch (status) {
      'あとで確認' => (c.pendingBg, c.pending),
      // 朱は確認印だけに使い、札を赤くしてエラーに見せない
      '確認済み' || '反映済み' => (c.addedBg, c.added),
      _ => (c.rule, c.ink),
    };
    return StatusTag(status, bg: bg, fg: fg);
  }

  List<String> _statuses(ManualState s, Utterance u) {
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

/// 同じ行の直しがぶつかったときに、相手の直しと自分の直しを並べて選んでもらう（ADR 0016）。
/// 「自分のにする」で保存したら true で閉じる
class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({required this.conflict, required this.mine, required this.save});
  final EditConflict conflict;

  /// 自分の直し。消そうとしていたなら null
  final String? mine;
  final Future<void> Function() save;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  var _busy = false;

  Future<void> _useMine() async {
    setState(() => _busy = true);
    await widget.save();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final x = widget.conflict;
    return Padding(
      padding: EdgeInsets.all(k.space.lg),
      child: MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('ほかの人が先にこの行を直しました', style: k.text.title),
              SizedBox(height: k.space.md),
              Text('元の行：${plain(x.line)}', style: k.text.small),
              SizedBox(height: k.space.md),
              ConflictPair(
                leftLabel: '${x.by}（${fmtDay(x.at)}）',
                left: x.theirs ?? '消しました',
                rightLabel: '自分',
                right: widget.mine ?? '消す',
              ),
              SizedBox(height: k.space.xl),
              Row(children: [
                MoonFilledButton(
                  onTap: _busy ? null : _useMine,
                  leading: _busy ? const ButtonLoader() : null,
                  label: Text(_busy ? '保存しています…' : '自分のにする'),
                ),
                SizedBox(width: k.space.sm),
                MoonOutlinedButton(
                  onTap: _busy ? null : () => Navigator.pop(context, false),
                  label: const Text('相手のままにする'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 「このノートを消しますか？」。消している間はボタンを押せなくし、二重に送らない。
/// 消せたら true で閉じる。失敗したら知らせて閉じ、ノートはそのまま
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.api, required this.manualId, required this.title});
  final Api api;
  final String manualId;
  final String title;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  var _busy = false;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteManual(widget.manualId);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(false);
      showError(nav.context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.all(k.space.lg),
      child: MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('このノートを消しますか？', style: k.text.title),
              SizedBox(height: k.space.md),
              Text('「${widget.title}」と、資料・記録・確認・履歴がすべて消えます。共有している人からも見えなくなります。元に戻せません。',
                  style: k.text.body),
              SizedBox(height: k.space.xl),
              Row(children: [
                // 危ない操作なので、消した行と同じ赤にする
                MoonFilledButton(
                  backgroundColor: k.colors.removed,
                  onTap: _busy ? null : _delete,
                  label: Text(_busy ? '消しています…' : '消す'),
                ),
                SizedBox(width: k.space.sm),
                MoonOutlinedButton(
                  onTap: _busy ? null : () => Navigator.pop(context, false),
                  label: const Text('やめる'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
