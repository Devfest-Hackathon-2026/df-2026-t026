---
paths:
  - "app/lib/**/*.dart"
---
# Flutter UI ルール

目的は「どのアプリにも見える既定値」ではなく、使い慣れた文書アプリの型（Mobbin で調べた Notion・Confluence・GitBook など）に沿いつつ、このアプリにしか無いもの（衝突の提示と確認印）をはっきり見せること。部品は moon_design（ADR 0004）、アイコンは lucide。`app/test/ui_rules_test.dart` が下の一部（禁止部品・アイコン・リテラル・影）を機械で検査する。

## 見た目の考え方

- 見た目はポップにする（design/pop-ui で導入）。「AI が作りがちな既定値」を避けるための抑制は、色数や装飾の少なさではなく、下の「ポップにしていい場所／しない場所」の線引きで保つ
- 画面の地はパステルのグラデーション（`shellGrad`）。マニュアル本文は白い紙（`PaperSheet`、上の両端をテープで留めた形）に置き、記録と確認は右のパネル（狭い画面ではタブ）に置く
- 色は差分と状態に使う。反映済みは緑、あとで確認は黄、条件付きは青、消えた行は赤。そこにポップの主役色（`accent`、コーラル）を主ボタンと選択中の印にだけ足す。一覧のタイルと付箋は、状態と紛れないパステル（`tiles` / `stickies`）を順に回してよい
- 目立たせるのは衝突の提示（マニュアル ／ 言われたこと）と確認印（朱）。確認印は日付印の形で、このアプリの記録が証拠になることを表す
- 食い違いは急がせない。食い違いは「あとで聞くこと」で、記録した時点で解決を求めない。見つけたら確認リストに入れるだけにし、確定の入力欄は利用者が「確認できたので記録する」を押してから開く。黄は面を塗らず、線と小さなタグだけに使う
- 「口頭で言われたこと」は付箋（`StickyNote`）で見せる。色と傾きは発言者から決め、マスキングテープを付ける
- タブはリキッドガラス風（`GlassTabs`）にする。半透明の面の上で白いピルが滑って移動する
- 書体は3つ。見出しは丸ゴシック（M PLUS Rounded 1c）、本文と UI は印字（BIZ UDPGothic）、手書き（Klee One）は「口頭で言われたこと」の本文だけに使う

## 情報配置

- 題名は上部バーではなく、内容の頭に大きく置く（`text.display`）。上部バーは戻る・パンくず・その画面全体の操作だけ
- 題名の下のメタ情報（記録の数・差分の数・あとで確認の数）は、それぞれ別の要素として並べる。`・` や ` · ` でつながない
- アプリを開くと最初に入力ページが出る。どのマニュアルかを先に選ばず、常時待ち受け（直前60秒をメモリ保持し、言われた後に1タップで切り出して送信）・テキスト（音声入力つき）・ファイル（PDF／画像）で入力できる。常時待ち受け中は「端末内で直前60秒を保持中（送信していません）」の案内と音量インジケータを出し、いつでも一時停止できる。同じ画面に「あとで確認」への導線と最近の記録を置き、上部バーの「マニュアルを確認」からマニュアル一覧へ進む
- 一覧は「題名と主ボタンを同じ行」にし、マニュアルはパステルのタイル（`tiles`）で並べる。タイルの中に記録数と状態をステッカー風のタグで置く
- マニュアル閲覧画面には入力欄を置かない。文書面にはマニュアル本文、右パネルには「記録した発言」だけを置く。発言の項目は「誰が・いつ（アバター・名前・日付）→ 本文 → 状態」の順に並べる
- 食い違いは別の画面（確認リスト）にまとめる。「あとで確認」と「確認済み」の2つに分け、項目は「誰が・いつ → 食い違い（マニュアル ／ 言われたこと）→ 理由か確認の結果」の順に並べる。確認済みの項目には、誰がいつ確認したかを必ず付ける。マニュアル画面からは上部バーのボタンでいつでも開ける
- 文書の変更行は、左余白の色線で示す。左余白の色線は変更の種類（反映済み・あとで確認）を表すときだけ使い、カードの枠の一辺を色付けする飾りには使わない
- マニュアルの食い違っている行には、行の横に「／ 誰（日付）：言われたこと」と「食い違い」のタグを出し、食い違っていることがその場で分かるようにする。行のどこを押しても確認リストを開く（その場で解決させない）
- 衝突は左右に並べ、どちらも同じ色（中立）で見せる。どちらが正しいかはアプリが決めない（spec）ので、赤／緑で塗り分けない。未解決であることだけを黄の印で示す。文言は「マニュアルの行 ／ 言われた行」の形を保つ
- 確認の結果を選ぶ所は、左右の比較と同じ並びの選択肢にする（左＝マニュアルのまま、右＝言われた通り、下＝別の内容）
- 狭い画面（`wideLayout` 未満）では、文書と記録した発言をタブで切り替える。タブの中にさらにタブを重ねない

## 部品

- 画面に見える部品は Moon（`Moon*`）か `lib/screens/common.dart` の自前部品だけを使う
- 使ってよい Material：`MaterialApp`・`Scaffold`・`Material`・`MaterialPageRoute`・`Theme`。Moon の入力欄が Material の祖先を要求するため、土台としてだけ使う
- 使わない Material：`Card`・`ListTile`・`AppBar`・`TabBar`/`Tab`・`Chip`/`ActionChip`・`ElevatedButton`/`FilledButton`/`OutlinedButton`/`TextButton`/`IconButton`/`FloatingActionButton`・`TextField`・`Radio`/`RadioListTile`/`RadioGroup`・`AlertDialog`/`showDialog`・`SnackBar`/`ScaffoldMessenger`・`CircularProgressIndicator`/`LinearProgressIndicator`・`CircleAvatar`・`Divider`/`VerticalDivider`
  - 代わり：ボタン→`MoonFilledButton`/`MoonOutlinedButton`/`MoonTextButton`/`MoonButton.icon`、入力→`MoonTextInput`/`MoonTextArea`、ダイアログ→`showMoonModal`、通知→`MoonToast`、読み込み中→`MoonCircularLoader`、タブ→`GlassTabs`（common.dart）、切り替え→`MoonSegmentedControl`、アバター→`MoonAvatar`、ラベル→`StatusTag`（common.dart、ステッカー風）
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

- 影・グラデーション・すりガラスは、ポップな部品（地のグラデーション、ガラスのタブと上部バー、付箋、紙、ステッカー、タイル）に限って使う。マニュアル本文の行や、衝突の左右の面には使わない。本文の区切りは罫線（`rule`）と左余白の色線で付ける
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
- 見出しを言い換えただけの説明文を付けない。絵文字は状態と画面の印（📌 あとで確認、✅ 反映済み・確認済み、⚡ 食い違い、💮 確認の答え、📚・🗂️ などの画面の印）にだけ使う。文の装飾には使わない

## 参考

- 調べた「AI が作りがちな見た目」の一覧：<https://impeccable.style/slop>、<https://cdn.jsdelivr.net/npm/pixelslop@0.3.8/dist/skill/resources/ai-slop-patterns.md>
- 情報配置と配色の型（Mobbin）
  - 文書と右パネル：[Notion](https://mobbin.com/screens/072bc230-1366-4039-9d25-cce13e422214)、[Confluence](https://mobbin.com/screens/15a602a9-da3a-4c0f-bbf2-91b7bad90033)、[Contractbook](https://mobbin.com/screens/555a19e0-da68-4f7a-8415-2bbcdf0d20ea)
  - 変更行の左余白の印：[GitBook](https://mobbin.com/screens/d8307789-31af-4bdd-b7cf-dab69a87dd95)、[Linear](https://mobbin.com/screens/6c14e085-9ff5-4e61-9a21-b04f1b0a3433)
  - 提案の受け入れ：[Grammarly](https://mobbin.com/screens/b727d76e-6475-4a20-a8bd-d0ad05569b30)、解決済みの記録：[Coda](https://mobbin.com/screens/fce42576-5c93-45c8-9083-c8fa1c4c2c69)
  - 左右の比較と選択：[Semrush](https://mobbin.com/screens/ed82aafc-c4dc-442d-87fc-359f7347f940)
  - 列見出しのある一覧：[HoneyBook](https://mobbin.com/screens/906dff27-49b0-4d21-bac0-7ffe6d027aa7)、[Cloudflare](https://mobbin.com/screens/fa5520ff-fda8-435f-b65b-bf910991fab4)
  - 外枠と文書面の配色：[Dropbox Dash](https://mobbin.com/screens/db24613b-901d-4574-9f74-134fdfaa52ab)
