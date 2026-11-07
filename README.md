# DiffNote（仮）

新人が、口頭で教わったことをマニュアルへの差分として記録し、矛盾に気づいて確認できる道具。仕様は [docs/spec/spec.md](docs/spec/spec.md)、開発のルールは [AGENTS.md](AGENTS.md)。

| ディレクトリ | 中身 |
|---|---|
| `app/` | Flutter クライアント（Web） |
| `api/` | Hono バックエンド |
| `infra/` | Terraform（Cloud Run・Firestore・Firebase Hosting・GitHub Actions 連携）。手順は [infra/README.md](infra/README.md) |
| `eval/` | 衝突検知の評価セットとスクリプト |
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

### 本物の Gemini と Firestore で動かす

API は環境変数で切り替える。認証は ADC（`gcloud auth application-default login`）。AI Studio の API キーは使わない。

| 変数 | 内容 | 既定 |
|---|---|---|
| `AI` | `gemini` で Vertex AI の Gemini を呼ぶ | 偽の Gemini |
| `STORE` | `firestore` で Firestore に保存する | メモリ |
| `GOOGLE_CLOUD_PROJECT` | GCP のプロジェクト ID | |
| `GOOGLE_CLOUD_LOCATION` | Vertex AI のリージョン | `global` |
| `GEMINI_MODEL` | モデル | `gemini-3.8-flash` |
| `ALLOW_ORIGIN` | CORS で許可するオリジン | すべて |
| `PORT` | ポート | `8787` |

```sh
AI=gemini STORE=firestore GOOGLE_CLOUD_PROJECT=<プロジェクト ID> pnpm dev
```

## テスト

```sh
cd api && pnpm test && pnpm typecheck
cd app && fvm flutter analyze && fvm flutter test
```

Firestore への保存も確かめるときは、エミュレータを立ててから回す。gcloud の `cloud-firestore-emulator` と Java が必要（Homebrew の `openjdk` は PATH に `/opt/homebrew/opt/openjdk/bin` を足す）。

```sh
gcloud emulators firestore start --host-port=127.0.0.1:8085    # 別のターミナルで
cd api && FIRESTORE_EMULATOR_HOST=127.0.0.1:8085 GOOGLE_CLOUD_PROJECT=demo-test pnpm test
```

衝突検知の評価は [eval/README.md](eval/README.md)。
