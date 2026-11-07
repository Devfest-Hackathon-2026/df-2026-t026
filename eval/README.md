# 衝突検知の評価

プロンプトやモデルを変えたら回し、変更前後の数字を PR に書く。

```sh
cd api
pnpm eval                 # Gemini（Vertex AI）で回す。GOOGLE_CLOUD_PROJECT と ADC が必要
pnpm eval -- --fake       # 偽の Gemini で、スクリプトが動くかだけ確かめる（数字に意味はない）
```

モデルは `GEMINI_MODEL=... pnpm eval` で変えられる。

## 指標

2つを**分けて**報告する。聞かれすぎると誰も使わなくなるので、後者も軽く見ない。

- **矛盾の取りこぼし率**：正解が `contradiction` のケースのうち、ほかに分類した割合
- **誤って聞きに来た率**：正解が `contradiction` 以外のケースのうち、`contradiction` にした割合

1つの発言から複数のパッチが出たときは、いちばん重い分類をその発言の判定にする（矛盾が1つでもあれば聞きに行くため）。パッチが出なかったときは `addition` 扱い（聞きに行かない）。

## ケース（`cases.json`）

| 項目 | 内容 |
|---|---|
| `id` | ケースの ID |
| `expected` | 正解の分類（`addition` / `qualification` / `contradiction`） |
| `note` | ケースの説明 |
| `today` | 発言を記録した日（YYYY-MM-DD） |
| `manual` | 現行マニュアルの全文 |
| `utterance` | 新人が入力する文 |

**いまのケースは仮のもの。** キッチンで働くメンバーへのインタビューで集めた実例に置き換える（目標20〜30件）。

いまの16件は、後輩のモック（`diff-note-mock`）の評価セット24件を次のように読み替えたもの。モックは「指示A と指示B を比べる」形だったので、指示A をマニュアルの1行として、関係のない節（出勤・身だしなみ）と一緒に埋め込み、指示B を「〜さんに『…』と言われた」という入力文にした。

| モックの分類 | この評価での分類 | 件数 |
|---|---|---|
| contradiction（矛盾） | `contradiction` | 6 |
| conditional（条件違い） | `qualification` | 6 |
| supplement（補足） | `addition` | 4 |
| update（更新）・same（同じ） | 入れていない（3分類への読み替えが分かれるため） | 8 |
