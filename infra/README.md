# infra（Terraform）

GCP 上の次のものを作る。手で作るのは、GCP プロジェクトそのものと課金アカウントのひも付けだけ。

- Cloud Run（API。`AI=gemini`・`STORE=firestore` で動く）と、そのサービスアカウント（Firestore・Vertex AI を使える）
- Firestore（ネイティブモード）
- Artifact Registry（API のイメージ置き場）
- Firebase Hosting（Web 版。`https://<プロジェクト ID>.web.app`）
- GitHub Actions からのデプロイ用の Workload Identity 連携とサービスアカウント（鍵は作らない。main ブランチのワークフローだけがデプロイできる）

state はいまはローカルに置く（`terraform apply` を回すのは1人の想定）。複数人で回すようになったら GCS に移す。

## 最初の1回

```sh
# 1. ログイン（ブラウザが開く）
gcloud auth login
gcloud auth application-default login

# 2. プロジェクトを作って課金をひも付ける
gcloud projects create <プロジェクト ID>
gcloud billing accounts list
gcloud billing projects link <プロジェクト ID> --billing-account=<課金アカウント ID>
gcloud auth application-default set-quota-project <プロジェクト ID>

# 3. 作る
cd infra
cp terraform.tfvars.example terraform.tfvars   # project_id を書き換える
terraform init
terraform apply

# 4. GitHub Actions がデプロイに使う値を、リポジトリの Variables に入れる
terraform output -json github_variables \
  | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
```

4 が済むと、main に push するたびに `.github/workflows/deploy.yml` が API（Cloud Run）と Web（Firebase Hosting）をデプロイする。済むまではデプロイのジョブは飛ばされる。

## 注意

- Firebase Hosting のサイト（`<プロジェクト ID>`）がすでにある場合、`terraform apply` が「すでにある」で止まる。そのときは取り込んでから回す：`terraform import google_firebase_hosting_site.web projects/<プロジェクト ID>/sites/<プロジェクト ID>`
- Cloud Run のイメージは Terraform では管理しない（初回だけ仮のイメージを置き、以後は GitHub Actions が差し替える）。環境変数やサービスアカウントを変えるときは Terraform で変える
- API は認証なしで公開している（デモ版は単一ユーザー固定のため）
