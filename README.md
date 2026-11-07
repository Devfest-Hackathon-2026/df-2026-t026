# DiffNote（仮）

新人が、口頭で教わったことをマニュアルへの差分として記録し、矛盾に気づいて確認できる道具。仕様は [docs/spec/spec.md](docs/spec/spec.md)、開発のルールは [AGENTS.md](AGENTS.md)。

| ディレクトリ | 中身 |
|---|---|
| `app/` | Flutter クライアント（Web） |
| `api/` | Hono バックエンド |
| `docs/` | 仕様・ADR |

## ローカルで動かす

必要なもの：Node.js 24 以上、pnpm、[FVM](https://fvm.app/)（Flutter のバージョンは `app/.fvmrc` で固定）、Chrome。

```sh
# API（偽の Gemini・メモリ上のデータで動く。GCP は不要）
cd api
pnpm install
pnpm dev            # http://localhost:8787

# アプリ（別のターミナルで）
cd app
fvm install
fvm flutter run -d chrome
```

アプリが呼ぶ API の URL は `--dart-define=API_URL=...` で変えられる（既定は `http://localhost:8787`）。

偽の Gemini（`api/src/fake-ai.ts`）は、「田中さんから、塩は小さじ1/2でいいと言われた」のような決まった言い回しだけを解釈する。デモの流れ：

1. 「田中さんから、塩は小さじ1/2でいいと言われた」→ 矛盾。確認先の候補と聞き方が出る
2. 「店長」に確認した結果を「1/2で統一」と記録 → マニュアルの行に「店長に確認 11/7」が付く
3. 「佐藤さんから、ご飯はおかわり1回まで無料と教わった」→ 追記
4. 「田中さんに、忙しい日は大盛りは200gまでと言われた」→ 条件付きの補足

## テスト

```sh
cd api && pnpm test && pnpm typecheck
cd app && fvm flutter analyze && fvm flutter test
```
