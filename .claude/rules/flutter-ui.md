---
paths:
  - "app/lib/**/*.dart"
---
# Flutter UI ルール

目的は「どのアプリにも見える既定値」ではなく、このアプリの題材から決めた見た目にすること。部品は moon_design（ADR 0004）、アイコンは lucide。`app/test/ui_rules_test.dart` が下の一部（禁止部品・アイコン・リテラル）を機械で検査する。

## 見た目の考え方

新人が現場で持つ手帳。マニュアルは「印字された紙」、口頭で言われたことは「手書きのメモ」、確認待ちは「付箋」、確認して確定したことは「確認印」。面・色・書体は、この4つのどれを表すかで決める。目立たせるのは衝突の提示（マニュアル ／ 言われたこと）と確認印だけで、他は静かにする。

## 部品

- 画面に見える部品は Moon（`Moon*`）か `lib/screens/common.dart` の自前部品だけを使う
- 使ってよい Material：`MaterialApp`・`Scaffold`・`Material`・`MaterialPageRoute`・`Theme`。Moon の入力欄が Material の祖先を要求するため、土台としてだけ使う
- 使わない Material：`Card`・`ListTile`・`AppBar`・`TabBar`/`Tab`・`Chip`/`ActionChip`・`ElevatedButton`/`FilledButton`/`OutlinedButton`/`TextButton`/`IconButton`/`FloatingActionButton`・`TextField`・`Radio`/`RadioListTile`/`RadioGroup`・`AlertDialog`/`showDialog`・`SnackBar`/`ScaffoldMessenger`・`CircularProgressIndicator`/`LinearProgressIndicator`・`CircleAvatar`・`Divider`/`VerticalDivider`
  - 代わり：ボタン→`MoonFilledButton`/`MoonOutlinedButton`/`MoonTextButton`/`MoonButton.icon`、入力→`MoonTextInput`/`MoonTextArea`、ダイアログ→`showMoonModal`、通知→`MoonToast`、読み込み中→`MoonCircularLoader`、タブ→`MoonTabBar`、選択→`MoonRadio`、ラベル→`MoonTag`
- 例外：日付選択だけは Moon に無いので `showDatePicker` を使う。色はテーマの `ColorScheme`（トークンから作る）に従わせる
- アイコンは `LucideIcons` だけ。`Icons.*` と、moon_design が再エクスポートする `MoonIcons` は使わない
- アイコンは、言葉だけでは意味が取りにくい所（戻る・コピー・日付・閉じる）と状態の印にだけ付ける。見出しや行ごとの飾りアイコンは付けない

## トークン

- 色・余白・角丸・文字スタイルは `context.tokens`（`lib/theme.dart` の `AppTokens`）から取る。`Color(0x…)`・`Colors.*`・数値を直接書いた `EdgeInsets`/`SizedBox`/`BorderRadius`/`fontSize` は `theme.dart` 以外に書かない
- Moon の色・角丸・書体・影も `theme.dart` でトークンから作る。Moon の既定（紫の主色 #5C33CF、純白・純黒）を画面に出さない
- 色は役割の名前で持つ（`ink`・`paper`・`sheet`・`added`・`removed`・`pending`・`stamp` など）。純白 `#FFFFFF`・純黒 `#000000` は使わない。補足の文字は `inkMuted` にし、灰色の文字を色付きの面に載せない
- 余白は `space.xs`(4)〜`space.xxl`(40) の段階だけ。まとまりの内側は狭く、まとまりの間は広くして、全部を同じ値にしない
- 角丸は役割で3つ：操作するもの（`radius.control`）、面（`radius.surface`）、手書きラベル（`radius.tape`）。何にでも同じ角丸を付けない

## 構成

- カードで全部を囲まない。一覧は余白と罫線（`rule`）で区切る。背景の違う面は「紙（マニュアル本文）」「付箋（確認待ち）」「確認印」のように意味のあるものにだけ使い、箱の中に箱を作らない
- 影・グラデーション・すりガラス・光彩を使わない
- 片側だけの太い色線を飾りに使わない。差分の行は行頭の印（`+`）と地の色で示す
- 文字は左揃え。中央揃えは、空状態のように画面に一つしかない短い案内だけ
- 番号（1・2・3）は、本当に順に進む手順にだけ付ける
- 主ボタン（filled）は、一つのまとまりにつき一つ。他は outlined か text にする
- メタ情報を `・` や ` · ` でつながない。誰・いつ・状態は、それぞれ別の要素（文字・タグ）として並べる
- 書体は2つ。印字（BIZ UDPGothic）は UI とマニュアル本文、手書き（Klee One）は「口頭で言われたこと」とその発言者・日付だけに使う。文書と口頭の違いを書体で表すので、他の用途に手書きを使わない
- 動きは利用者の操作に応えるもの（開く・閉じる・確定）だけ。弾む動き、表示時の入場アニメーションを付けない

## 状態

- データを読む画面は、読み込み中・空・エラーを必ず出す。エラーには再読み込みの操作を付ける
- 送信中はそのボタン自体を読み込み中の表示にして、二重送信を防ぐ
- 空状態は次にすることへの誘いにする（何ができるかと、そのためのボタン）

## 文言

- ボタンは動詞か「何をするか」で書く（「差分を作る」「確定する」「承認して反映」）。「OK」「はい」「送信」は使わない。同じ操作は流れの中で同じ名前にする
- エラーは何が起きて、どうすればいいかを書く。謝らない
- 見出しを言い換えただけの説明文を付けない。絵文字・「✨」は使わない

## 参考

- 調べた「AI が作りがちな見た目」の一覧：<https://impeccable.style/slop>、<https://cdn.jsdelivr.net/npm/pixelslop@0.3.8/dist/skill/resources/ai-slop-patterns.md>
