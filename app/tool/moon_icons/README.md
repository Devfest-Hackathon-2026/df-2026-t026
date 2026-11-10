# 使う字だけに絞った MoonIcons

`moon_icons` 1.1.0 の `MoonIcons.ttf`（1.4MB）から、アプリが描く1字（U+ED49、`MoonIcons.generic_info_16_light`）だけを残したもの。`moon_design` の `MoonTextInput` が `errorText` を出すとき、`MoonErrorMessage` がこの字を添える。アプリは `MoonIcons` を自分では使わない。

Flutter Web は `FontManifest.json` のフォントを最初の画面の前に全部取りに行く。`moon_icons` が宣言するフォントはアプリの `pubspec.yaml` から外せないので、`tool/web_postbuild.dart` がビルドの `MoonIcons.ttf` をこれに差し替える（マニフェストの family と道は変えない）。`main.dart.js` から拾った MoonIcons の字が `moonIconsCodePoints` に全部入っていなければ、差し替えずに元のまま残し、理由を出す。

## ライセンス

`moon_icons` は MIT License（Copyright (c) 2024 Yolo Group。pub のパッケージの `LICENSE` と、GitHub の coingaming/moon_flutter_icons で確かめた）。手を加えて配ってよく、写しには著作権表示と許諾表示を付ける条件なので、同じ `LICENSE` をここに置いた。フォントの中（name テーブル）には著作権の表記が無い（svg2ttf と Fontello の生成表記だけ）。Web のビルドの `assets/NOTICES` にも、`moon_icons` のライセンスが今までどおり入る。

## CI で落ちたとき

CI（`.github/workflows/ci.yml` の `app`）は Web をビルドして後処理を流し、「差し替えた」と出なければ落ちる。本番のデプロイは止めない（元のフォントのまま出す）ので、ここで気づく。後処理が出した理由で直す所が違う。

- 「絞ったフォントに無い字を使っている」：アプリが描く MoonIcons の字が増えた。下の手順で作り直す。
- 「読み切れない」：dart2js の出力の形が変わり、字を拾えていない。`tool/web_postbuild.dart` の拾い方（`_moonIconData`）を、ビルドの `main.dart.js` に合わせて直す。「IconData 0 個、MoonIcons の文字列 0 回」なら、アプリが MoonIcons を描かなくなった（このフォントごと要らない）。

## 作り直すとき

`moon_icons` の版を上げたとき（`test/web_postbuild_test.dart` が版を見ている）や、後処理が「絞ったフォントに無い字を使っている」と出したとき。

```sh
cd app
uvx --from fonttools pyftsubset ~/.pub-cache/hosted/pub.dev/moon_icons-<版>/lib/fonts/MoonIcons.ttf \
  --unicodes=U+ED49 --name-IDs='*' --name-languages='*' --output-file=tool/moon_icons/MoonIcons.ttf
```

`--unicodes` には、ビルドの `main.dart.js` にある `(<番号>,"MoonIcons","moon_icons",…)` の番号を全部書き（前に付く `new A.dg` などは IconData の縮めた名前で、ビルドごとに変わる）、`tool/web_postbuild.dart` の `moonIconsCodePoints` とテストの版を揃える。

## 確かめたこと（fonttools、1.1.0 から作ったとき）

- cmap は U+ED49 だけ（グリフは `.notdef` と U+ED49 の2つ）。1,116 バイト。
- U+ED49 の輪郭（RecordingPen で 50 命令）、送り幅（1024）、外接枠（0, 0, 856, 849）が元と同じ。
- unitsPerEm（1024）、hhea の ascent・descent・lineGap、OS/2 の sTypo・usWin の値が元と同じ。アイコンの縦の位置が変わらない。
