import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_screen.dart';
import 'common.dart';

/// 確認リストの外（マニュアルの行・記録直後のモーダル）から食い違いを開く。戻ると確認リストに出るよう、リストを挟む
void openCheckViaList(NavigatorState nav, ManualController c, String checkId) {
  nav.push(MaterialPageRoute(builder: (_) => CheckListScreen(c: c)));
  nav.push(MaterialPageRoute(builder: (_) => CheckScreen(c: c, checkId: checkId)));
}

/// マニュアルと食い違っていた指示の一覧。記録した時点では解決を求めず、ここに「あとで確認」として残す
class CheckListScreen extends StatelessWidget {
  const CheckListScreen({super.key, required this.c});
  final ManualController c;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state!;
        void open(Check chk) =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => CheckScreen(c: c, checkId: chk.id)));
        return Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: ['DiffNote（仮）', s.title, '確認リスト']),
            Expanded(
              child: Container(
                color: k.colors.canvas,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl),
                  child: Narrow(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      PageTitle('確認リスト', meta: [
                        Text('マニュアルと食い違っていた指示です。聞けるときに確認して、決まったら記録します', style: k.text.small),
                      ]),
                      SizedBox(height: k.space.xxl),
                      Text('あとで確認（${s.openChecks.length}）', style: k.text.title),
                      SizedBox(height: k.space.sm),
                      if (s.openChecks.isEmpty)
                        Text('マニュアルと食い違う指示は、いまはありません', style: k.text.small)
                      else ...[
                        const Rule(),
                        for (final chk in s.openChecks.reversed) ...[_openRow(context, s, chk, open), const Rule()],
                      ],
                      SizedBox(height: k.space.xxl),
                      Text('確認済み（${s.resolvedChecks.length}）', style: k.text.title),
                      SizedBox(height: k.space.sm),
                      if (s.resolvedChecks.isEmpty)
                        Text('確認して記録すると、ここに残ります。後で別の人に聞かれたときに見せられます', style: k.text.small)
                      else ...[
                        const Rule(),
                        for (final chk in s.resolvedChecks.reversed) ...[_resolvedRow(context, s, chk, open), const Rule()],
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _row(BuildContext context, {required VoidCallback onTap, required Utterance u, required List<Widget> body}) {
    final k = context.tokens;
    return MoonMenuItem(
      onTap: onTap,
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
      label: Speaker(name: u.speaker, day: u.saidAt),
      content: Padding(
        padding: EdgeInsets.only(top: k.space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body),
      ),
    );
  }

  /// あとで確認：誰が・いつ → 食い違い → 理由
  Widget _openRow(BuildContext context, ManualState s, Check chk, void Function(Check) open) {
    final k = context.tokens;
    return _row(
      context,
      onTap: () => open(chk),
      u: s.utterance(chk.utteranceId),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(s.patch(chk.patchId).text)}', style: k.text.heading),
        SizedBox(height: k.space.xs),
        Text(chk.reason, style: k.text.small),
      ],
    );
  }

  /// 確認済み：誰が・いつ言ったか → 食い違っていたこと → 誰がいつ確認して何に決まったか
  Widget _resolvedRow(BuildContext context, ManualState s, Check chk, void Function(Check) open) {
    final k = context.tokens;
    final r = chk.resolution!;
    return _row(
      context,
      onTap: () => open(chk),
      u: s.utterance(chk.utteranceId),
      body: [
        Text('${plain(chk.conflictLine ?? '')} ／ ${plain(s.patch(chk.patchId).text)}', style: k.text.small),
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
}
