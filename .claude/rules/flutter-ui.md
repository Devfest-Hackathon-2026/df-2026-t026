---
paths:
  - "app/lib/**/*.dart"
---
# Flutter UI ルール

目的は「どのアプリにも見える既定値」ではなく、使い慣れた文書アプリの型（Mobbin で調べた Notion・Confluence・GitBook など）に沿いつつ、このアプリにしか無いもの（衝突の提示と確認印）をはっきり見せること。部品は moon_design（ADR 0004）、アイコンは lucide。`app/test/ui_rules_test.dart` が下の一部（禁止部品・アイコン・リテラル・影）を機械で検査する。

## 見た目の考え方

- 画面は「温かい灰色の外枠（`shell`）」と「白い文書面（`canvas`）」の2層。マニュアル本文は文書面に置き、記録と確認は右のパネル（狭い画面ではタブ）に置く
- 色は差分と状態にだけ使う。反映済みは緑、あとで確認は黄、条件付きは青、消えた行は赤。主ボタンは黒（`ink`）で、色の付いた主ボタンは作らない
- 目立たせるのは衝突の提示（マニュアル ／ 言われたこと）と確認印（朱）だけ。確認印は日付印の形で、このアプリの記録が証拠になることを表す
- 食い違いは急がせない。食い違いは「あとで聞くこと」で、記録した時点で解決を求めない。見つけたら確認リストに入れるだけにし、確定の入力欄は利用者が「確認できたので記録する」を押してから開く。黄は面を塗らず、線と小さなタグだけに使う
- 書体は2つ。印字（BIZ UDPGothic）は UI とマニュアル本文、手書き（Klee One）は「口頭で言われたこと」の本文だけに使う

## 情報配置

- 題名は上部バーではなく、内容の頭に大きく置く（`text.display`）。上部バーは戻る・パンくず・その画面全体の操作だけ
- 題名の下のメタ情報（記録の数・差分の数・あとで確認の数）は、それぞれ別の要素として並べる。`・` や ` · ` でつながない
- 一覧は「題名と主ボタンを同じ行」「列見出しのある表」にする。カードを並べない。狭い画面では列をやめ、数や状態を名前の下に並べる
- 右パネルは「記録した発言」だけを置く。項目は「誰が・いつ（アバター・名前・日付）→ 本文 → 状態」の順に並べる
- 食い違いは別の画面（確認リスト）にまとめる。「あとで確認」と「確認済み」の2つに分け、項目は「誰が・いつ → 食い違い（マニュアル ／ 言われたこと）→ 理由か確認の結果」の順に並べる。確認済みの項目には、誰がいつ確認したかを必ず付ける。マニュアル画面からは上部バーのボタンでいつでも開ける
- 文書の変更行は、左余白の色線で示す。左余白の色線は変更の種類（反映済み・あとで確認）を表すときだけ使い、カードの枠の一辺を色付けする飾りには使わない
- マニュアルの食い違っている行には、行の横に「／ 誰（日付）：言われたこと」と「食い違い」のタグを出し、食い違っていることがその場で分かるようにする。行のどこを押しても確認リストを開く（その場で解決させない）
- 衝突は左右に並べ、どちらも同じ色（中立）で見せる。どちらが正しいかはアプリが決めない（spec）ので、赤／緑で塗り分けない。未解決であることだけを黄の印で示す。文言は「マニュアルの行 ／ 言われた行」の形を保つ
- 確認の結果を選ぶ所は、左右の比較と同じ並びの選択肢にする（左＝マニュアルのまま、右＝言われた通り、下＝別の内容）
- 狭い画面（`wideLayout` 未満）では、文書と記録した発言をタブで切り替える。タブの中にさらにタブを重ねない。記録の入力欄はどのタブからでも使える位置に置く

## 部品

- 画面に見える部品は Moon（`Moon*`）か `lib/screens/common.dart` の自前部品だけを使う
- 使ってよい Material：`MaterialApp`・`Scaffold`・`Material`・`MaterialPageRoute`・`Theme`。Moon の入力欄が Material の祖先を要求するため、土台としてだけ使う
- 使わない Material：`Card`・`ListTile`・`AppBar`・`TabBar`/`Tab`・`Chip`/`ActionChip`・`ElevatedButton`/`FilledButton`/`OutlinedButton`/`TextButton`/`IconButton`/`FloatingActionButton`・`TextField`・`Radio`/`RadioListTile`/`RadioGroup`・`AlertDialog`/`showDialog`・`SnackBar`/`ScaffoldMessenger`・`CircularProgressIndicator`/`LinearProgressIndicator`・`CircleAvatar`・`Divider`/`VerticalDivider`
  - 代わり：ボタン→`MoonFilledButton`/`MoonOutlinedButton`/`MoonTextButton`/`MoonButton.icon`、入力→`MoonTextInput`/`MoonTextArea`、ダイアログ→`showMoonModal`、通知→`MoonToast`、読み込み中→`MoonCircularLoader`、タブ→`MoonTabBar`、切り替え→`MoonSegmentedControl`、アバター→`MoonAvatar`、ラベル→`MoonTag`
- 例外：日付選択だけは Moon に無いので `showDatePicker` を使う。色はテーマの `ColorScheme`（トークンから作る）に従わせる
- アイコンは `LucideIcons` だけ。`Icons.*` と、moon_design が再エクスポートする `MoonIcons` は使わない
- アイコンは、言葉だけでは意味が取りにくい所（戻る・コピー・日付・閉じる）と状態の印にだけ付ける。見出しや行ごとの飾りアイコンは付けない
- 発言者のアバター（名前の頭文字）は「誰が言ったか」を表す情報なので付けてよい。色は名前から決め、`avatars` のくすんだ色だけを使う

## トークン

- 色・余白・角丸・文字スタイルは `context.tokens`（`lib/theme.dart` の `AppTokens`）から取る。`Color(0x…)`・`Colors.*`・数値を直接書いた `EdgeInsets`/`SizedBox`/`BorderRadius`/`fontSize` は `theme.dart` 以外に書かない
- Moon の色・角丸・書体・影も `theme.dart` でトークンから作る。Moon の既定（紫の主色 #5C33CF、純黒）を画面に出さない
- 色は役割の名前で持つ（`shell`・`canvas`・`ink`・`inkMuted`・`rule`・`added`・`removed`・`pending`・`qualified`・`stamp` など）。文字は温かい黒（`ink`）で、純黒 `#000000` は使わない。補足の文字は `inkMuted`
- 余白は `space.xs`(4)〜`space.xxl`(40) の段階だけ。まとまりの内側は狭く、まとまりの間は広くして、全部を同じ値にしない
- 角丸は役割で分ける：操作するもの（`radius.control`）、面（`radius.surface`）、アバター（`radius.round`）。何にでも同じ角丸を付けない

## 構成

- 影・グラデーション・すりガラス・光彩を使わない。面の区切りは地の色の違いと罫線（`rule`）で付ける
- 箱の中に箱を作らない
- 文字は左揃え。中央揃えは、空状態のように画面に一つしかない短い案内だけ
- 番号（1・2・3）は、本当に順に進む手順にだけ付ける
- 主ボタン（filled）は、一つのまとまりにつき一つ。他は outlined か text にする
- 動きは利用者の操作に応えるもの（開く・閉じる・確定）だけ。弾む動き、表示時の入場アニメーションを付けない

## 状態

- データを読む画面は、読み込み中・空・エラーを必ず出す。エラーには再読み込みの操作を付ける
- パネルの切り替えなど、利用者が選んだ表示はデータが変わっても勝手に切り替えない
- 送信中はそのボタン自体を読み込み中の表示にして、二重送信を防ぐ
- 空状態は次にすることへの誘いにする（何ができるかと、そのためのボタン）

## 文言

- ボタンは動詞か「何をするか」で書く（「差分を作る」「確定する」「承認して反映」）。「OK」「はい」「送信」は使わない。同じ操作は流れの中で同じ名前にする
- エラーは何が起きて、どうすればいいかを書く。謝らない
- 見出しを言い換えただけの説明文を付けない。絵文字・「✨」は使わない

## 参考

- 調べた「AI が作りがちな見た目」の一覧：<https://impeccable.style/slop>、<https://cdn.jsdelivr.net/npm/pixelslop@0.3.8/dist/skill/resources/ai-slop-patterns.md>
- 情報配置と配色の型（Mobbin）
  - 文書と右パネル：[Notion](https://mobbin.com/screens/072bc230-1366-4039-9d25-cce13e422214)、[Confluence](https://mobbin.com/screens/15a602a9-da3a-4c0f-bbf2-91b7bad90033)、[Contractbook](https://mobbin.com/screens/555a19e0-da68-4f7a-8415-2bbcdf0d20ea)
  - 変更行の左余白の印：[GitBook](https://mobbin.com/screens/d8307789-31af-4bdd-b7cf-dab69a87dd95)、[Linear](https://mobbin.com/screens/6c14e085-9ff5-4e61-9a21-b04f1b0a3433)
  - 提案の受け入れ：[Grammarly](https://mobbin.com/screens/b727d76e-6475-4a20-a8bd-d0ad05569b30)、解決済みの記録：[Coda](https://mobbin.com/screens/fce42576-5c93-45c8-9083-c8fa1c4c2c69)
  - 左右の比較と選択：[Semrush](https://mobbin.com/screens/ed82aafc-c4dc-442d-87fc-359f7347f940)
  - 列見出しのある一覧：[HoneyBook](https://mobbin.com/screens/906dff27-49b0-4d21-bac0-7ffe6d027aa7)、[Cloudflare](https://mobbin.com/screens/fa5520ff-fda8-435f-b65b-bf910991fab4)
  - 外枠と文書面の配色：[Dropbox Dash](https://mobbin.com/screens/db24613b-901d-4574-9f74-134fdfaa52ab)
