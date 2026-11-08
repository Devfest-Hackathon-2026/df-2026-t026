# infra（Terraform）

GCP 上の次のものを作る。手で作るのは、GCP プロジェクトそのものと課金アカウントのひも付けだけ。

- Cloud Run（API。`AI=gemini`・`STORE=firestore` で動き、合言葉 `PASSCODE` を確かめる）と、そのサービスアカウント（Firestore・Vertex AI を使える）
- Firestore（ネイティブモード）
- Artifact Registry（API のイメージ置き場）
- Firebase Hosting（Web 版。`https://<プロジェクト ID>.web.app`）
- GitHub Actions からのデプロイ用の Workload Identity 連携とサービスアカウント（鍵は作らない。main ブランチのワークフローだけがデプロイできる）
- 予算アラート（1か月の予算の 50%・90%・100% で、課金アカウントの管理者にメールが届く。超えても止まりはしない）

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

# 3. Firebase を追加する（そのアカウントで初めて Firebase を使うときは、規約への同意がコンソールでしかできないため）
#    https://console.firebase.google.com/ で「既存の Google Cloud プロジェクトに Firebase を追加」し、規約に同意する

# 4. 作る
cd infra
cp terraform.tfvars.example terraform.tfvars   # project_id・billing_account・passcode を書き換える
terraform init
# 3 でできた Firebase と Hosting のサイトを取り込む
terraform import google_firebase_project.this projects/<プロジェクト ID>
terraform import google_firebase_hosting_site.web projects/<プロジェクト ID>/sites/<プロジェクト ID>
terraform apply

# 5. GitHub Actions がデプロイに使う値を、リポジトリの Variables に入れる
terraform output -json github_variables \
  | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
```

5 が済むと、main に push するたびに `.github/workflows/deploy.yml` が API（Cloud Run）と Web（Firebase Hosting）をデプロイする。済むまではデプロイのジョブは飛ばされる。

## メンバーがローカルで本物の Gemini を使えるようにする

`terraform.tfvars` の `team_members` にメンバーの Google アカウントのメールアドレスを足して `terraform apply` する。Vertex AI を呼ぶ権限（`roles/aiplatform.user`）と、ADC のクォータ用プロジェクトにこのプロジェクトを指定する権限（`roles/serviceusage.serviceUsageConsumer`）が付く。Firestore の権限は付けない。外すときは一覧から消して `terraform apply` する。

```hcl
team_members = ["member1@gmail.com", "member2@gmail.com"]
```

メンバーの呼び出しも、このプロジェクトの課金アカウントに請求される（予算アラートにも数えられる）。メンバー側の手順はリポジトリ直下の README の「本物の Gemini と Firestore で動かす」にある。

## 注意

- 3 を飛ばして `terraform apply` すると、Firebase の追加が 403（The caller does not have permission）で止まる。3 をしてから取り込めばよい
- Cloud Run のイメージは Terraform では管理しない（初回だけ仮のイメージを置き、以後は GitHub Actions が差し替える）。環境変数やサービスアカウントを変えるときは Terraform で変える
- API は誰でも呼べる設定で公開し、合言葉で守っている（[ADR 0003](../docs/adr/0003-demo-passcode.md)）。合言葉を変えるときは `terraform.tfvars` の `passcode` を書き換えて `terraform apply` する。合言葉は Cloud Run の設定画面でプロジェクトのメンバーから見える
