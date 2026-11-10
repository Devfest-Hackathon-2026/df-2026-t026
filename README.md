<div align="center">

<img src="docs/logo.png" width="480" alt="DiffNote のロゴ">

# DiffNote

**教わったことを、ノートへの差分として残す。食い違いに気づいて、確かめられる。**

<img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white">
<img alt="Hono" src="https://img.shields.io/badge/Hono-E36002?style=flat-square&logo=hono&logoColor=white">
<img alt="TypeScript" src="https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white">
<img alt="Cloud Run" src="https://img.shields.io/badge/Cloud_Run-4285F4?style=flat-square&logo=googlecloud&logoColor=white">
<img alt="Firestore" src="https://img.shields.io/badge/Firestore-DD2C00?style=flat-square&logo=firebase&logoColor=white">
<img alt="Gemini on Vertex AI" src="https://img.shields.io/badge/Gemini_on_Vertex_AI-8E75B2?style=flat-square&logo=googlegemini&logoColor=white">
<img alt="Terraform" src="https://img.shields.io/badge/Terraform-844FBA?style=flat-square&logo=terraform&logoColor=white">
<a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-17173D?style=flat-square"></a>

[デモ（ログインが必要）](https://diff-note-514023.web.app) ・ [できること](#できること) ・ [アーキテクチャ](#アーキテクチャ) ・ [ローカルで動かす](#ローカルで動かす) ・ [仕様](docs/spec/spec.md)

<img src="app/assets/help/wide/check.png" width="820" alt="確認リストの画面。ノートの行と言われたことの食い違い、確認する相手の候補、聞き方の例が並ぶ">

</div>

新人が、口頭で教わったことや自分で書いたことをノート（職場のマニュアルや自分用のメモ）への差分として記録し、食い違いに気づいて確認できる道具。仕様は [docs/spec/spec.md](docs/spec/spec.md)、開発のルールは [AGENTS.md](AGENTS.md)。

## できること

- **言われたことをそのまま入れる**：テキスト、音声入力、直前60秒をさかのぼる録音、PDF・画像から記録できる
- **ノートへの差分にする**：どのノートのどの行が変わるかを Gemini が案にし、誰がいつ言ったかと一緒に積む。本文は上書きしない
- **食い違いに気づく**：ノートや確定済みの記録と比べ、同じ内容（`same`）・追記（`addition`）・条件付きの補足（`qualification`）・矛盾（`contradiction`）に分ける
- **聞いて確かめる**：矛盾には確認する相手の候補と聞き方の例が出る。確かめた結果は「誰に・いつ・どう決まったか」としてノートに残る
- **一緒に使う**：ノートを共有し、教える側が確認に直接答えられる

## アーキテクチャ

<div align="center">
<img src="docs/architecture.png" width="720" alt="アーキテクチャ図。利用者の端末では、直前60秒の音声から切り出した部分だけが Flutter Web のアプリに渡る。アプリは Firebase Hosting から読み込まれ、Cloud Run の API（Hono）に HTTPS と WebSocket でつなぐ。API は Firestore を読み書きし、Vertex AI の Gemini を記録1件につき1回呼び、音声は Speech-to-Text v2 で文字にする。確定の記録は Gemini を通らず Firestore にだけ書く。GitHub Actions が Firebase Hosting と Artifact Registry 経由で Cloud Run にデプロイし、Terraform がリソースと権限を作る">
<br>
<sub>アイコン：svgl・gilbarbara/logos・Google Cloud product icons・Lucide。ロゴは各社の商標。<a href="https://github.com/caru-ini/stack-diagram">stack-diagram</a> で作成</sub>
</div>

### 設計の要点

- **Gemini には意味の判断だけをさせる**：振り分け・差分化・分類・聞き方を、記録1件につき1回の問い合わせにまとめる（[ADR 0006](docs/adr/0006-assess-in-one-call.md)）。Gemini に状態は持たせず、記録・差分・確認の結果はバックエンドが Firestore に持つ。確定の記録は Gemini を通らない
- **出力は JSON スキーマで受けて確かめる**：Gemini に JSON スキーマを指定し、返ってきたものをバックエンドで検証してから保存する
- **RAG にしない**：関係しそうな所を探して渡すのではなく、ノート全文と確定済みの記録を毎回載せて比べる。費用と待ちはコンテキストキャッシュで抑え、資料のあるノートでは資料を明示のキャッシュに入れる
- **本文は上書きしない**：元の本文に反映した差分を積み、ある時点の版はそこまでの差分を当て直して作る。版は Firestore で自前で持ち、Git は使わない（[ADR 0001](docs/adr/0001-manual-as-base-plus-patches.md)・[0023](docs/adr/0023-versions-in-firestore.md)）
- **遅い返事を待ち続けない**：12秒で返らなければ2本目を並べて送り、先に返ったほうを使う（[ADR 0002](docs/adr/0002-gemini-calls.md)）

### 衝突検知の評価

架空のノートと発言で作った評価セット（`eval/`）を、`gemini-3.8-flash`（Vertex AI）で回した結果（2026-11-10 時点）。矛盾を見落とす割合と、矛盾でないものを矛盾として聞きに来る割合を分けて見る。

| ケース | 矛盾の取りこぼし率 | 誤って聞きに来た率 |
|---|---|---|
| 資料なし（18件） | 0%（0/6） | 0%（0/12） |
| 資料なしに、関係の無い約3万トークンの資料をまぜる（18件） | 0%（0/6） | 0%（0/12） |
| 資料つき（24件） | 0%（0/12） | 0%（0/12） |

ケースはまだ少なく、件数を増やすと変わりうる。回し方・指標の定義は [eval/README.md](eval/README.md)。

## リポジトリの構成

| ディレクトリ | 中身 |
|---|---|
| `app/` | Flutter クライアント（Web） |
| `api/` | Hono バックエンド |
| `infra/` | Terraform（Cloud Run・Firestore・Firebase Hosting・GitHub Actions 連携）。手順は [infra/README.md](infra/README.md) |
| `eval/` | 衝突検知の評価セットとスクリプト |
| `docs/` | 仕様（`spec/`）・ADR（`adr/`。一覧は [docs/adr/README.md](docs/adr/README.md)）・設計書（`design/`）・審査用のモック用データ案（`mock-data/`） |

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

アプリを開いたら、ID `demo`・パスワード `demo` でログインする。本番に配ったのと同じ ID（`kanade`・`haruto`・`hikaru`・`chinatsu`）でも入れるが、パスワードはどれもローカル専用の `demo`。どれもメモリ上のデータで動かすときだけ起動時に作り、見本のノートが入っているのは `demo` と `newbie` だけ。`demo` には、新人（ID `newbie`・パスワード `demo`）のノート「閉店作業メモ」が共有されていて、答える確認が2件待っている。`demo` で答えたあと `newbie` で入ると、通知で確かめられる（ADR 0017・0020）。

アプリが呼ぶ API の URL は `--dart-define=API_URL=...` で変えられる（既定は `http://localhost:8787`）。

偽の Gemini（`api/src/fake-ai.ts`）は、「田中さんから、塩は小さじ1/2でいいと言われた」のような決まった言い回しだけを解釈する。デモの流れ：

1. 「田中さんから、塩は小さじ1/2でいいと言われた」→ 矛盾。確認先の候補と聞き方が出る
2. 「店長」に確認した結果を「1/2で統一」と記録 → ノートの行に「（聞いた日） 店長に確認」が付く（聞いた日は既定で今日）
3. 「佐藤さんから、ご飯はおかわり1回まで無料と教わった」→ 追記
4. 「田中さんに、忙しい日は大盛りは200gまでと言われた」→ 条件付きの補足

### 本物の Gemini と Firestore で動かす

API は環境変数で切り替える。認証は ADC（`gcloud auth application-default login`）。AI Studio の API キーは使わない。

| 変数 | 内容 | 既定 |
|---|---|---|
| `AI` | `gemini` で Vertex AI の Gemini と Speech-to-Text v2 を呼ぶ | 偽の Gemini と偽の書き起こし |
| `STORE` | `firestore` で Firestore に保存する | メモリ |
| `GOOGLE_CLOUD_PROJECT` | GCP のプロジェクト ID | |
| `GOOGLE_CLOUD_LOCATION` | Vertex AI のリージョン | `global` |
| `GEMINI_MODEL` | モデル | `gemini-3.8-flash` |
| `ALLOW_ORIGIN` | CORS で許可するオリジン | すべて |
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

`STORE=firestore` を付けると、ローカルからでも本番のデータベースに書いてしまう（メンバーは読むだけの権限なので、書こうとすると権限エラーになる）。保存まで確かめたいときは、下のエミュレータを使う。

本番に記録されたものは、[Firestore のコンソール](https://console.cloud.google.com/firestore/databases/-default-/data/panel/users?project=diff-note-514023)で見られる。ノートはログイン ID ごとに分かれ、`users/{ID}/manuals/{ノート}/` の下の `utterances`（言われたこと）・`patches`（差分）・`checks`（分類・理由・聞き方）に記録が並び、共有の相手は `shares`、資料は `materials` にある。名前とアイコンは `users/{ID}` そのもの、共有されたノートの索引は `users/{ID}/shared`、未整理メモは `users/{ID}/memos`、通知を最後に見た時刻は `users/{ID}/notices/seen`、ログインは `accounts`・`sessions` にある。アカウントの作り方は [infra/README.md](infra/README.md) の「使う人のアカウントを作る」。

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
