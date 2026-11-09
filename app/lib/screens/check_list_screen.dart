import 'package:flutter/material.dart';

import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_screen.dart';
import 'common.dart';
import 'sidebar.dart';
import 'tab_bar.dart';

/// 確認リストの外（マニュアルの行・記録直後のモーダル）から食い違いを開く。戻ると確認リストに出るよう、リストを挟む
void openCheckViaList(NavigatorState nav, ManualController c, String checkId, {RouteSettings? settings}) {
  // settings: ノートの上に積むときの印（tab_bar.dart の aboveNote）。下のタブバーの「ノート」で、積んだ分を外して戻れるようにする
  nav.push(MaterialPageRoute(settings: settings, builder: (_) => CheckListScreen(c: c, initialCheckId: checkId)));
  // 広い画面では確認リストの右に詳細が出るので、詳細の画面は重ねない
  if (MediaQuery.sizeOf(nav.context).width < nav.context.tokens.wideLayout) {
    nav.push(MaterialPageRoute(builder: (_) => CheckScreen(c: c, checkId: checkId)));
  }
}

/// マニュアルと食い違っていた指示の一覧。記録した時点では解決を求めず、ここに「あとで確認」として残す。
/// 広い画面では、左に一覧、右に選んだ食い違いの詳細を並べ、行き来せずに確認から記録までできるようにする
class CheckListScreen extends StatefulWidget {
  const CheckListScreen({super.key, required this.c, this.initialCheckId});
  final ManualController c;

  /// 広い画面で最初に右に出す食い違い。省略時はいちばん新しいもの
  final String? initialCheckId;

  @override
  State<CheckListScreen> createState() => _CheckListScreenState();
}

class _CheckListScreenState extends State<CheckListScreen> {
  ManualController get c => widget.c;

  /// 広い画面で右に出している食い違い。利用者が選んだものは、確定して一覧の位置が変わっても切り替えない
  late String? _selected =
      widget.initialCheckId ?? (c.state!.openChecks.lastOrNull ?? c.state!.resolvedChecks.lastOrNull)?.id;

  void _push(Check chk) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => CheckScreen(c: c, checkId: chk.id)));

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state!;
        return Scaffold(
          extendBody: true,
          bottomNavigationBar: showsNoteTabBar(context) ? NoteTabBar(c: c, current: NoteTab.checks) : null,
          body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: ['DiffNote（仮）', s.title, '確認リスト']),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                if (box.maxWidth < k.wideLayout) return _scroll(_list(s, onOpen: _push));
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: k.panelWidth,
                    child: _scroll(_list(s, selected: _selected, onOpen: (chk) => setState(() => _selected = chk.id))),
                  ),
                  Container(width: k.hairline, color: k.colors.rule),
                  Expanded(child: _scroll(_detail(s))),
                ]);
              }),
            ),
          ]))),
        );
      },
    );
  }

  Widget _scroll(Widget child) {
    final k = context.tokens;
    return Builder(builder: (context) => SingleChildScrollView(
      padding: belowTabBar(context, EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl)),
      child: Narrow(child: child),
    ));
  }

  Widget _detail(ManualState s) {
    final id = _selected;
    if (id == null || !s.checks.any((x) => x.id == id)) {
      return Text('左の一覧から選ぶと、ここに出ます', style: context.tokens.text.small);
    }
    // 選び直したら、確定の入力欄などは閉じた状態から始める
    return CheckDetail(key: ValueKey(id), c: c, checkId: id);
  }

  Widget _list(ManualState s, {String? selected, required void Function(Check) onOpen}) {
    final k = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PageTitle('確認リスト'),
      SizedBox(height: k.space.xxl),
      Text('あとで確認（${s.openChecks.length}）', style: k.text.title),
      SizedBox(height: k.space.md),
      if (s.openChecks.isEmpty)
        Text('食い違いは、いまはありません', style: k.text.small)
      else
        for (final chk in s.openChecks.reversed) ...[
          _openRow(s, chk, selected: chk.id == selected, onTap: () => onOpen(chk)),
          SizedBox(height: k.space.md),
        ],
      SizedBox(height: k.space.xxl),
      Text('確認済み（${s.resolvedChecks.length}）', style: k.text.title),
      SizedBox(height: k.space.md),
      if (s.resolvedChecks.isEmpty)
        Text('確認済みの食い違いは、まだありません', style: k.text.small)
      else
        for (final chk in s.resolvedChecks.reversed) ...[
          _resolvedRow(s, chk, selected: chk.id == selected, onTap: () => onOpen(chk)),
          SizedBox(height: k.space.md),
        ],
    ]);
  }

  Widget _row({required bool selected, required VoidCallback onTap, required Utterance u, required List<Widget> body}) {
    final k = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(k.space.lg),
          decoration: BoxDecoration(
            color: k.colors.canvas,
            borderRadius: k.radius.paper,
            // 選んでいない行も同じ太さの白い枠にして、選んだときに中身がずれないようにする
            border: Border.all(color: selected ? k.colors.action : k.colors.canvas, width: k.hairline * 2),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Speaker(name: u.speaker, day: u.saidAt),
            SizedBox(height: k.space.sm),
            ...body,
          ]),
        ),
      ),
    );
  }

  /// あとで確認：誰が・いつ → 食い違い → 理由
  Widget _openRow(ManualState s, Check chk, {required bool selected, required VoidCallback onTap}) {
    final k = context.tokens;
    return _row(
      selected: selected,
      onTap: onTap,
      u: s.utterance(chk.utteranceId),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(s.patch(chk.patchId).text)}', style: k.text.heading),
        SizedBox(height: k.space.xs),
        Text(chk.reason, style: k.text.small),
      ],
    );
  }

  /// 確認済み：誰が・いつ言ったか → 食い違っていたこと → 誰がいつ確認して何に決まったか
  Widget _resolvedRow(ManualState s, Check chk, {required bool selected, required VoidCallback onTap}) {
    final k = context.tokens;
    final r = chk.resolution!;
    return _row(
      selected: selected,
      onTap: onTap,
      u: s.utterance(chk.utteranceId),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(s.patch(chk.patchId).text)}', style: k.text.small),
        SizedBox(height: k.space.sm),
        // 小さい斜めの印でなく、ノートの行と同じ「(丸) 店長 11/7 に確認」の形にし、決まったことをその下に出す
        Speaker(name: r.decidedBy, day: r.decidedAt, after: 'に確認'),
        SizedBox(height: k.space.xs),
        Text(r.note, style: k.text.body),
        if (r.note != plain(r.text)) ...[
          SizedBox(height: k.space.xs),
          Text('確定した内容：${plain(r.text)}', style: k.text.small),
        ],
      ],
    );
  }
}
