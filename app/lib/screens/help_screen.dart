import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../theme.dart';
import 'common.dart';
import 'font_licenses_screen.dart';
import 'sidebar.dart';

/// 使い方。画面に説明文を並べる代わりに、ここにまとめる。
/// スクショの撮り直し方は assets/help/README.md に書く
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TopBar(crumbs: const ['使い方'], trailing: MoonTextButton(
          label: const Text('ライセンスを読む'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FontLicensesScreen())),
        )),
        Expanded(
          child: Narrow(
            child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
              const PageTitle('使い方'),
              SizedBox(height: k.space.xl),
              const _Section(n: '1', title: 'ノートを作る', shot: 'new_note', lines: [
                'ノートは、職場のマニュアルや自分用のメモのことです。サイドバー（スマホは左上の三本線）の「ノート」の右の＋から作ります。',
                '今あるマニュアルやメモは、本文の欄に貼り付けるか、「ファイルから読み取る」で PDF や写真から読み取ります。欄へのドロップや貼り付けでも読み取れます。読み取った本文は、AI が見出しと箇条書きに整えて入れます。',
                '「## 見出し」「- 項目」のようなマークダウンは、1行ずつ整えて表示します。貼り付けた平文は「マークダウンに整える」で、AI が見出しと箇条書きに整えた案を出します。',
                '本文が無ければ、題名だけ入れて白紙から始められます。',
              ]),
              const _Section(n: '2', title: '言われたことを書く', shot: 'input', lines: [
                '「言われたことを記録」のページに、言われたことを書いて「ノートと照らし合わせる」を押します。「田中さんから、〜と言われた」のように書くと、誰がいつ言ったかも入ります。',
                'どのノートのことかは選ばなくてかまいません。記録先が「自動」のままなら、AI が関係するノートを選びます。分かっているときは「記録先：自動」を押して選べます。いくつ選んでもかまいません。',
                '1つの話がいくつものノートに関わるときは、ノートごとに結果が出ます。関係するノートが見つからなかったときは、結果の「記録先を選ぶ」でノートを選ぶと、照らし合わせ直します。',
                'マイクを押すと声で入力でき、＋から PDF や画像を添えられます。PC では貼り付けやドロップでも添えられ、Ctrl / ⌘ + Enter でも送れます。スマホでは、＋の「写真を撮る」でその場で撮って添えられます。',
              ]),
              const _Section(n: '3', title: 'ノートに書き込む', shot: 'review', lines: [
                '照らし合わせると、追加や補足はそのままノートに書き込み、ノートと同じ内容なら記録だけ残して、結果を入力欄の下に出します。食い違いは書き込まずに確認リストに入れます。',
                '書き込んだ結果の「確かめる」か、ノートのページの自分が記録した発言の付箋を押すと「記録した結果」が開き、どの行がどう変わったかを見られます。誰が言ったかと、言われた日もここで直せます。',
                '誰が言ったかが分からなかったときは、まだ書き込まずに結果を出すので、その「確かめる」で「ノートに書き込む前の確認」を開き、入れてから「ノートに書き込む」を押します。',
                'まだ書き込んでいないうちは、言われたことの中身が違っていたら「言われたことを直す」、書き込む文だけを直したいなら「書き込む内容を直す」、ノートを変えたくなければ「書き込まない」を押します。書き込んだあとは、ノートの行を直接直します。',
                '記録した発言は、ノートのページの右（スマホは「発言」のタブ）に付箋で並び、書き込み済み・あとで確認・確認済みなどの状態が付きます。',
              ]),
              const _Section(n: '4', title: '食い違いは、あとで確認する', shot: 'check', lines: [
                'ノートと食い違うことを言われても、その場で決めなくてかまいません。そのノートの確認リストの「あとで確認」に入ります。',
                '確認リストは、ノートのページの「確認リスト」から開きます。サイドバー（スマホは三本線）の「あとで確認」には、全部のノートの食い違いがノートごとに並びます。',
                '聞けるときに確認リストから開くと、誰に確認するかの候補と、聞き方の例が出ます。聞き方の例は、右のボタンでコピーできます。食い違った結果の「確かめる」からも、その食い違いを開けます。',
                '聞いて決まったら「聞いた結果を記録する」を押し、確認した相手と聞いた日を入れ、「ノートのまま」「（言った人）の言う通り」「別の内容に決まった」から選んで「確認済みにする」を押します。「確認済み」に移り、誰にいつ確認したかが残るので、後で別の人に聞かれたときに見せられます。',
                '前に確認して決まったことと食い違ったときは、結果の「記録を見せて、ノートのままにする」で、聞き直さずにその場で確認済みにできます。相手に見せる文も、右のボタンでコピーできます。',
              ]),
              const _Section(n: '5', title: '履歴を見る', shot: 'history', lines: [
                'ノートのページの「履歴」で、ノートの版と食い違いを1本のグラフで見られます。緑の線が版、黄の枝がまだ確認していない食い違いです。',
                '行を押すと、その版で増えた行と消えた行が出ます。ノートと同じ内容だった記録や、書き込まなかった記録は、その版の「この版のあいだの記録」に並びます。',
              ]),
              SizedBox(height: k.space.lg),
              Text('ほかにできること', style: k.text.title),
              SizedBox(height: k.space.lg),
              const _Section(title: 'リワインドで、言われた後にメモする', shot: 'rewind', lines: [
                '「言われたことを記録」の題名の右の「リワインド」を ON にすると、端末の中で直前60秒の音を持ち続けます。ボタンを押すまでは、送っていません。',
                '言われた後に大きな丸いボタンを押すと、その前に言われたことを文字にして「未整理メモ」にためます。続けて何度でも押せます。',
                'ON の間は、メモを押すと書き直して、その1件だけをノートと照らし合わせられます。書き直した文は、欄の外を押すと残ります。OFF にしてからメモを押すと入力欄に入り、続けて押すと1つにまとめられます。',
                '要らないメモは、付箋の右上のバツで消せます。メモは、ほかの端末で開いても同じものが出ます。',
              ]),
              const _Section(title: 'ノートを直接直す', shot: 'edit', lines: [
                'ノートの行を押すと、その場で書き換え・下に行を足す・消すができます。いちばん下の「行を足す」からも書き足せます。',
                '欄の右端のチェックか Enter で保存し、バツでその行を消します。Enter で保存すると、すぐ下に次の行を続けて書けます。欄の外を押すと、書きかけの文は残さずに閉じます。',
                '保存すると、ほかの行や確認済みの記録、資料と食い違っていないかを AI が確かめます。食い違っていれば確認リストに入ります。',
                '行の左の線は、緑が言われて変わった行、黄があとで確認の行です。行の横の名前を押すと、言われたことや確認の記録が開きます。食い違っている行は、押すと書き換えの欄ではなく確認リストが開きます。',
              ]),
              const _Section(title: '資料と照らし合わせる', shot: 'materials', lines: [
                '店のマニュアルや授業の資料は、ノートのページの「資料」から「資料を足す」で付けられます。題名と本文を貼り付けて「この文を資料にする」を押すか、「ファイルから読み取る」で PDF や写真を選びます。PDF は1つで30ページまで、写真は10枚までです。',
                '資料は書き換えない原本です。言われたことやノートに書いた行が資料と食い違うと、ノートとの食い違いと同じように確認リストに入ります。',
                '資料を押すと中身をページごとに見られ、食い違っている行には印が付きます。資料と食い違った確認では、「資料で前後を見る」で資料のその行を開けます。',
                '消すときは、資料を開いて右上の「…」から「資料を消す」を押します。',
              ]),
              const _Section(title: 'ノートを探す', shot: 'search', lines: [
                'サイドバー（スマホは三本線）の「ノートを探す」で、全部のノートの題名と本文から言葉を探せます。出てきた行を押すと、そのノートのその行が開きます。',
                '資料と、言われたことの記録は探しません。',
              ]),
              const _Section(title: 'ノートを共有して一緒に直す', shot: 'share', lines: [
                'ノートのページの「共有」から、相手のログイン ID を入れて共有します。相手のサイドバーの「共有されたノート」に出ます。やめるときは、「共有」を開いて相手の右の「外す」を押します。',
                '共有された人も、言われたことの記録・ノートへの書き込み・行を直すこと・確認済みにすること・共有の相手を足すことができます。直してもらった行には相手の名前が付き、食い違えば確認リストに入ります。',
                '共有された人が確認リストを開くと、誰に確認するかの候補と聞き方の例は出ず、そのまま自分で答えて確定できます。答えた確認には「〇〇が決定」と出ます。共有されたノートの食い違いは、サイドバーの「あとで確認」の「聞かれていること」に並びます。',
                '同じ行をほかの人が先に直していたら、相手の直しと自分の直しが並んで出るので、どちらにするかを選びます。',
                '言われたことの記録を直すことと、ノートに書き込むかを決めることは、記録した本人だけができます。ほかの人の付箋を押すと、言われたことと記録した人が出ます。',
                'ノートに書き込んだ記録と確定した記録も、発言者と日付は記録した本人が直せます。言われたことの文面は、ノートに入った行のもとなので直せません。',
                'ノートを消すことは、ノートの持ち主だけができます。ノートの右上の「…」から「ノートを消す」を押します。資料・記録・確認・履歴もすべて消え、元に戻せません。',
              ]),
              const _Section(title: '通知を見る・名前とアイコンを変える', shot: 'notices', lines: [
                'サイドバー（スマホは三本線のメニュー）のいちばん下の自分の名前を押すと、「通知」が開きます。自分のノートで、共有した人が確認に答えたり行を直したりすると、ここに出ます。押すと、そのノートが開きます。',
                '名前とアイコンは、通知のページの「名前とアイコンを変える」から変えます。同じページのいちばん下の「ログアウトする」で、ほかの ID に入り直せます。',
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
