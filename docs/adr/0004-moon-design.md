# 0004 画面の部品は moon_design、アイコンは lucide にする

- 日付：2026-11-08
- 状態：採用

## 背景

- アプリは Material の既定の部品（Card・ListTile・AppBar・FAB など）と、シード色から作った配色のままで、どのアプリにも見える見た目だった。
- 見た目の判断を毎回その場でしていると、生成された UI にありがちな既定値（カードの多用、同じ角丸と影、紫の主色など）に戻りやすい。

## 決定

- 画面の部品は [moon_design](https://pub.dev/packages/moon_design)（1.1.0、MIT）を使う。
- アイコンは [lucide_icons_flutter](https://pub.dev/packages/lucide_icons_flutter)（4.0.2、MIT）を使う。
- 色・余白・角丸・書体は `app/lib/theme.dart` のトークンにまとめ、Moon のテーマもそこから作る。
- 何を使い、何を使わないかは `.claude/rules/flutter-ui.md` に書き、一部を `app/test/ui_rules_test.dart` で検査する。

## 知っておくこと

- moon_design の GitHub リポジトリ（coingaming/moon_flutter）は 2025-10 にアーカイブされ、pub.dev でも一覧に出ない（unlisted）。v1 は「パッチ以外の更新はしない」と README にある。2026-11 時点で Flutter 3.47.7 での解析・テスト・Web ビルドは通ることを確かめた。
- Flutter の更新で動かなくなったときは、Moon を使っている箇所を自前の部品に置き換える。Moon の部品は画面から直接使っているので、置き換えはファイルごとになる。
- moon_design は Moon Icons のフォント（約 1.2MB、ほぼ削られない）を同梱するので、Web 版の初回読み込みがその分重くなる。

## 採らなかった案

- Material のままテーマだけ作り込む：部品の形（ListTile・Card など）が Material らしさの大部分で、テーマだけでは変わりきらない。
- 部品を全部自前で作る：ハッカソンの期間では入力欄・モーダル・トーストまで作る余裕がない。
