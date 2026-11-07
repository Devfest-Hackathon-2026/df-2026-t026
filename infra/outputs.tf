output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "web_url" {
  value = "https://${google_firebase_hosting_site.web.site_id}.web.app"
}

# GitHub リポジトリの Variables に入れる値（README の手順で一括登録する）
output "github_variables" {
  value = {
    GCP_PROJECT_ID = var.project_id
    GCP_REGION     = var.region
    WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
    DEPLOYER_SA    = google_service_account.deployer.email
  }
}
