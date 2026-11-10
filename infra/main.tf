resource "google_project_service" "this" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "speech.googleapis.com",
    "sts.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------- データ ----------

resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
  # 消した・壊したデータを7日前まで戻せるようにし、データベースごと消す操作も止める
  point_in_time_recovery_enablement = "POINT_IN_TIME_RECOVERY_ENABLED"
  delete_protection_state           = "DELETE_PROTECTION_ENABLED"
  depends_on                        = [google_project_service.this]
}

# ---------- API（Cloud Run） ----------

resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = "diff-note"
  format        = "DOCKER"
  depends_on    = [google_project_service.this]
}

resource "google_service_account" "api" {
  account_id   = "diff-note-api"
  display_name = "DiffNote API（Cloud Run）"
}

resource "google_project_iam_member" "api" {
  for_each = toset(["roles/datastore.user", "roles/aiplatform.user", "roles/speech.client"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name                = "diff-note-api"
  location            = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.api.email
    scaling {
      # 1台は止めずに置き、最初の応答で起動を待たせない
      min_instance_count = 1
      max_instance_count = 2
    }
    containers {
      # 初回だけ置くイメージ。以後は GitHub Actions がビルドしたイメージに差し替える
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      # 止まっていたサーバーの起動を速くするため、起動時だけ CPU を上乗せする。resources を書くと cpu_idle の既定が外れるので、
      # 今の値（1 vCPU・リクエストの外では CPU を絞る）も書く。メモリは、10MB までのファイルの読み取りが重なっても足りるよう 1GiB にする
      resources {
        limits = {
          cpu    = "1000m"
          memory = "1Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }
      env {
        name  = "AI"
        value = "gemini"
      }
      env {
        name  = "STORE"
        value = "firestore"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = var.gemini_location
      }
      env {
        name  = "GEMINI_MODEL"
        value = var.gemini_model
      }
      env {
        name  = "ALLOW_ORIGIN"
        value = "https://${google_firebase_hosting_site.web.site_id}.web.app,https://${google_firebase_hosting_site.web.site_id}.firebaseapp.com"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }
  depends_on = [google_project_service.this]
}

# ブラウザから直接呼ぶので公開する。API は配った ID とパスワードのログインで守る（ADR 0009）
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------- Web（Firebase Hosting） ----------

resource "google_firebase_project" "this" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [google_project_service.this]
}

resource "google_firebase_hosting_site" "web" {
  provider   = google-beta
  project    = var.project_id
  site_id    = var.project_id
  depends_on = [google_firebase_project.this]
}

# ---------- GitHub Actions からのデプロイ（Workload Identity 連携。鍵は作らない） ----------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  # main ブランチのワークフローだけがデプロイできる
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"refs/heads/main\""
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deployer" {
  account_id   = "github-deployer"
  display_name = "GitHub Actions のデプロイ用"
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/firebasehosting.admin",
    "roles/run.developer",
    "roles/serviceusage.apiKeysViewer",
    "roles/serviceusage.serviceUsageConsumer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Cloud Run に API 用のサービスアカウントを付けたままデプロイするために必要
resource "google_service_account_iam_member" "deployer_act_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# ---------- ローカルで本物の Gemini を試すメンバー ----------

# 各自の Google アカウント（ADC）で Vertex AI と Speech-to-Text を呼ぶための権限。serviceUsageConsumer は ADC の
# クォータ用プロジェクトにこのプロジェクトを指定するために要る。Firestore は、使ってみた記録をみんなで確かめられるよう
# 読むだけにする（本番のデータは書き換えさせない）
resource "google_project_iam_member" "team" {
  for_each = {
    for pair in setproduct(var.team_members, ["roles/aiplatform.user", "roles/serviceusage.serviceUsageConsumer", "roles/speech.client", "roles/datastore.viewer"]) :
    "${pair[0]} ${pair[1]}" => { email = pair[0], role = pair[1] }
  }
  project = var.project_id
  role    = each.value.role
  member  = "user:${each.value.email}"
}

# ---------- 予算アラート ----------

data "google_project" "this" {}

# 使いすぎに気づくためのメール通知（課金アカウントの管理者に届く）。超えても止まりはしない
resource "google_billing_budget" "this" {
  # 利用者の認証情報で呼ぶとクォータ用のプロジェクトの指定が要るので、user_project_override のある google-beta で作る
  provider        = google-beta
  billing_account = var.billing_account
  display_name    = "DiffNote（${var.project_id}）"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }
  amount {
    specified_amount {
      units = tostring(var.budget_amount)
    }
  }
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  depends_on = [google_project_service.this]
}

# ---------- 稼働の監視 ----------

# API が落ちたことに気づくためのメール通知。5分おきに /health を見て、続けて失敗したら知らせる
resource "google_monitoring_uptime_check_config" "api" {
  display_name = "DiffNote API /health"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/health"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }
  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = trimprefix(google_cloud_run_v2_service.api.uri, "https://")
    }
  }
  depends_on = [google_project_service.this]
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "DiffNote の障害の連絡先"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.this]
}

resource "google_monitoring_alert_policy" "api_down" {
  display_name          = "DiffNote API が応答しない"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "/health の失敗が5分続く"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.api.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }
      trigger {
        count = 1
      }
    }
  }
}
