# DiffNote（仮）

新人が、口頭で教わったことをマニュアルへの差分として記録し、矛盾に気づいて確認できる道具。仕様は [docs/spec/spec.md](docs/spec/spec.md)、開発のルールは [AGENTS.md](AGENTS.md)。

| ディレクトリ | 中身 |
|---|---|
| `app/` | Flutter クライアント（Web） |
| `api/` | Hono バックエンド |
| `infra/` | Terraform（Cloud Run・Firestore・Firebase Hosting・GitHub Actions 連携）。手順は [infra/README.md](infra/README.md) |
| `eval/` | 衝突検知の評価セットとスクリプト |
| `docs/` | 仕様・ADR |

## ブランチと公開

- 作業ブランチは `dev` から切り、`dev` に PR を出す（GitHub の既定ブランチは `dev`）
- `dev` は手元で動かして確かめる場所。デプロイはしない
- `dev` → `main` の PR をマージすると、GitHub Actions が本番（Cloud Run・Firebase Hosting）にデプロイする

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
| `PASSCODE` | API の合言葉。決めると `X-Passcode` ヘッダーで一致しないリクエストを 401 にする（[ADR 0003](docs/adr/0003-demo-passcode.md)） | 確かめない |
| `HOST` | 待ち受けるアドレス | `127.0.0.1`（自分のマシンからだけ） |
| `PORT` | ポート | `8787` |

```sh
# 本物の Gemini で試す（データはメモリ。GCP の権限が要る）
AI=gemini GOOGLE_CLOUD_PROJECT=diff-note-514023 pnpm dev
```

権限は、プロジェクトの管理者が Terraform の `team_members` にメールアドレスを足して付ける（[infra/README.md](infra/README.md)）。付いたら、自分の Google アカウントで次を1回だけする。

```sh
gcloud auth application-default login
gcloud auth application-default set-quota-project diff-note-514023
```

`STORE=firestore` を付けると、ローカルからでも本番のデータベースに書いてしまう。保存まで確かめたいときは、下のエミュレータを使う。

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
