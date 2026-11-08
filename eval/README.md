# 衝突検知の評価

プロンプトやモデルを変えたら回し、変更前後の数字を PR に書く。

```sh
cd api
pnpm eval                 # Gemini（Vertex AI）で回す。GOOGLE_CLOUD_PROJECT と ADC が必要
pnpm eval -- --fake       # 偽の Gemini で、スクリプトが動くかだけ確かめる（数字に意味はない）
```

モデルは `GEMINI_MODEL=... pnpm eval` で変えられる。

## 結果の残し方と比べ方

回すたびに `eval/results/` に2つのファイルを書く（コミットしない）。

- `<日時>-<モデル>.json`：指標とケースごとの判定・理由・時間。次に比べるときに使う
- `<日時>-<モデル>.md`：PR にそのまま貼る表（指標・混同行列）

変更前後を比べるときは、変更前のブランチで回してから、変更後のブランチで前回の JSON を渡す。

```sh
pnpm eval                                              # 変更前（dev など）
pnpm eval -- --compare ../eval/results/<変更前>.json    # 変更後
```

`--compare` を付けると、表が「変更前 ／ 変更後」の2列になり、判定が変わったケースと新しく足したケースも出る。

## 複数のマニュアルへの振り分け（`multi.mts`）

正解のマニュアルに別のマニュアルを2冊まぜて3冊にし、振り分けの正答率と分類の指標を出す（ADR 0006）。

```sh
pnpm exec node ../eval/multi.mts             # 関係の薄い節だけのマニュアルをまぜる
pnpm exec node ../eval/multi.mts --overlap   # 話題が重なるマニュアル（仕込み・厨房の衛生など）をまぜる
```

## 指標

2つを**分けて**報告する。聞かれすぎると誰も使わなくなるので、後者も軽く見ない。

- **矛盾の取りこぼし率**：正解が `contradiction` のケースのうち、ほかに分類した割合
- **誤って聞きに来た率**：正解が `contradiction` 以外のケースのうち、`contradiction` にした割合

1つの発言から複数のパッチが出たときは、いちばん重い分類をその発言の判定にする（矛盾が1つでもあれば聞きに行くため）。パッチが出なかったときは `addition` 扱い（聞きに行かない）。

## ケース（`cases.json`）

| 項目 | 内容 |
|---|---|
| `id` | ケースの ID |
| `expected` | 正解の分類（`same` / `addition` / `qualification` / `contradiction`） |
| `note` | ケースの説明 |
| `today` | 発言を記録した日（YYYY-MM-DD） |
| `manual` | 現行マニュアルの全文 |
| `utterance` | 新人が入力する文 |

**いまのケースは仮のもの。** キッチンで働くメンバーへのインタビューで集めた実例に置き換える（目標20〜30件）。

いまの18件は、後輩のモック（`diff-note-mock`）の評価セット24件を次のように読み替えたもの。モックは「指示A と指示B を比べる」形だったので、指示A をマニュアルの1行として、関係のない節（出勤・身だしなみ）と一緒に埋め込み、指示B を「〜さんに『…』と言われた」という入力文にした。

| モックの分類 | この評価での分類 | 件数 |
|---|---|---|
| contradiction（矛盾） | `contradiction` | 6 |
| conditional（条件違い） | `qualification` | 6 |
| supplement（補足） | `addition` | 4 |
| same（同じ） | `same` | 2 |
| update（更新） | 入れていない（読み替えが分かれるため。[#10](https://github.com/df-dev-kuma/diff-note/issues/10)） | 6 |
