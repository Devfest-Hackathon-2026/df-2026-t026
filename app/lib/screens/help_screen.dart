import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';
import 'sidebar.dart';

/// 使い方。画面に説明文を並べる代わりに、ここにまとめる。
/// 画面は今後変わるので暫定とし、スクショの撮り直し方は assets/help/README.md に書く
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['使い方（暫定）']),
        Expanded(
          child: Narrow(
            child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
              const PageTitle('使い方（暫定）'),
              SizedBox(height: k.space.xl),
              const _Section(n: '1', title: 'ノートを作る', shot: 'new_note', lines: [
                'ノートは、職場のマニュアルや自分用のメモのことです。サイドバー（スマホは左上の三本線）の「ノート」の右の＋から作ります。',
                '今あるマニュアルやメモは、本文の欄に貼り付けるか、「ファイルから読み取る」で PDF や写真から読み取ります。欄へのドロップや貼り付けでも読み取れます。読み取った本文は、AI が見出しと箇条書きに整えて入れます。',
                '「## 見出し」「- 項目」のようなマークダウンは、1行ずつ整えて表示します。貼り付けた平文は「マークダウンに整える」で、AI が見出しと箇条書きに整えた案を出します。',
                '本文が無ければ、題名だけ入れて白紙から始められます。',
              ]),
              const _Section(n: '2', title: '言われたことを書く', shot: 'input', lines: [
                '「言われたことを記録」のページに、言われたことを書いて「ノートと照らし合わせる」を押します。「鈴木先輩から、〜と言われた」のように書くと、誰がいつ言ったかも入ります。',
                'どのノートのことかは選ばなくてかまいません。記録先が「自動」のままなら、AI が関係するノートを選びます。分かっているときは「記録先：自動」を押して選べます。',
                'マイクを押すと声で入力でき、＋から PDF や画像を添えられます。PC では貼り付けやドロップでも添えられ、Ctrl / ⌘ + Enter でも送れます。',
              ]),
              const _Section(n: '3', title: 'ノートに書き込む', shot: 'review', lines: [
                '照らし合わせると、追加や補足はそのままノートに書き込み、ノートと同じ内容なら記録だけ残して、結果を下に知らせます。食い違いは書き込まずに確認リストに入れます。',
                '知らせの「確かめる」か、ノートのページの発言の付箋を押すと「ノートに書き込む前の確認」が開き、どの行がどう変わったかを見られます。誰が言ったかが分からなかったときは、照らし合わせた後にこの確認が開くので、入れてから「ノートに書き込む」を押します。',
                '言われたことの中身が違っていたら「言われたことを直す」、書き込む文だけを直したいなら「書き込む内容を直す」を押します。',
              ]),
              const _Section(n: '4', title: '食い違いは、あとで確認する', shot: 'check', lines: [
                'ノートと食い違うことを言われても、その場で決めなくてかまいません。確認リストの「あとで確認」に入ります。',
                '聞けるときに確認リストから開くと、誰に確認するかの候補と、聞き方の例が出ます。',
                '聞いて決まったら「聞いた結果を記録する」で残します。「確認済み」に移り、誰にいつ確認したかが残るので、後で別の人に聞かれたときに見せられます。',
              ]),
              const _Section(n: '5', title: '履歴を見る', shot: 'history', lines: [
                'ノートのページの「履歴」（スマホは下のタブ）で、ノートの版と食い違いを1本のグラフで見られます。緑の線が版、黄の枝がまだ確認していない食い違いです。',
                '行を押すと、その版で増えた行と消えた行が出ます。ノートと食い違わなかった記録は、その版の「この版のあいだの記録」に並びます。',
              ]),
              SizedBox(height: k.space.lg),
              Text('ほかにできること', style: k.text.title),
              SizedBox(height: k.space.lg),
              const _Section(title: 'リワインドで、言われた後にメモする', shot: 'rewind', lines: [
                '「言われたことを記録」の題名の右の「リワインド」を ON にすると、端末の中で直前60秒の音を持ち続けます。送ってはいません。',
                '言われた後に大きな丸いボタンを押すと、その前の発話を文字にして「未整理メモ」にためます。続けて何度でも押せます。',
                'ON の間は、メモを押すと書き直して、その1件だけをノートと照らし合わせられます。OFF にしてからメモを押すと入力欄に入り、続けて押すと1つにまとめられます。',
              ]),
              const _Section(title: 'ノートを直接直す', shot: 'edit', lines: [
                'ノートの行を押すと、その場で書き換え・下に行を足す・消すができます。いちばん下の「行を足す」からも書き足せます。',
                '保存すると、ほかの行や確認済みの記録と食い違っていないかを AI が確かめます。食い違っていれば確認リストに入ります。',
              ]),
              const _Section(title: 'ノートを共有して一緒に直す', shot: 'share', lines: [
                'ノートのページの「共有」から、相手のログイン ID を入れて共有します。相手のサイドバーの「共有されたノート」に出ます。',
                '共有された人も、言われたことの記録・ノートへの書き込み・行を直すこと・確認済みにすること・共有の相手を足すことができます。直してもらった行には相手の名前が付き、食い違えば確認リストに入ります。',
                '共有された人が確認リストを開くと、誰に確認するかの候補と聞き方の例は出ず、そのまま自分で答えて確定できます。答えた確認には「〇〇 が決定」と出ます。',
                '同じ行をほかの人が先に直していたら、相手の直しと自分の直しが並んで出るので、どちらにするかを選びます。',
                '言われたことの記録を直すことと、ノートに書き込むかを決めることは、記録した本人だけができます。ほかの人の付箋を押すと、言われたことと記録した人が出ます。',
                'ノートに書き込んだ記録と確定した記録は、証拠として残すので、記録した本人も直せません。',
                'ノートを消すことは、ノートの持ち主だけができます。',
              ]),
              const _Section(title: '名前とアイコンを変える', shot: 'profile', lines: [
                'サイドバー（スマホは三本線のメニュー）のいちばん下の自分の名前から変えられます。',
              ]),
            ]),
          ),
        ),
      ])),
    );
  }
}

/// 1つの節。白い面に、題名・説明・スクショの順に並べる
class _Section extends StatelessWidget {
  const _Section({this.n, required this.title, required this.shot, required this.lines});

  /// 順に進む流れの番号。流れの外の節には付けない
  final String? n;
  final String title;

  /// assets/help/{wide,narrow}/ の画像の名前（拡張子なし）
  final String shot;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    // 開いた画面の幅に合わせて、PC の幅かスマホの幅で撮ったものを出す
    final width = showsSidebar(context) ? 'wide' : 'narrow';
    return Padding(
      padding: EdgeInsets.only(bottom: k.space.lg),
      child: PaperSheet(
        padding: EdgeInsets.all(k.space.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (n != null) ...[
              Container(
                width: k.space.xl,
                height: k.space.xl,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.colors.ink, width: k.hairline)),
                child: Text(n!, style: k.text.label),
              ),
              SizedBox(width: k.space.sm),
            ],
            Expanded(child: Text(title, style: k.text.title)),
          ]),
          for (final l in lines) ...[SizedBox(height: k.space.sm), Text(l, style: k.text.body)],
          SizedBox(height: k.space.lg),
          DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(border: Border.all(color: k.colors.rule, width: k.hairline), borderRadius: k.radius.paper),
            child: ClipRRect(
              borderRadius: k.radius.paper,
              child: Image.asset('assets/help/$width/$shot.png', semanticLabel: '$title の画面'),
            ),
          ),
        ]),
      ),
    );
  }
}
