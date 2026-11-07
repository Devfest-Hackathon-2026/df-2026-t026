variable "project_id" {
  description = "GCP のプロジェクト ID。Firebase Hosting のサイト名（<project_id>.web.app）にもなる"
  type        = string
}

variable "region" {
  description = "Cloud Run・Firestore・Artifact Registry のリージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "github_repository" {
  description = "デプロイを許可する GitHub リポジトリ（owner/name）"
  type        = string
  default     = "df-dev-kuma/diff-note"
}

variable "gemini_model" {
  description = "API が使う Gemini のモデル"
  type        = string
  default     = "gemini-3.8-flash"
}

variable "gemini_location" {
  description = "Vertex AI で Gemini を呼ぶリージョン"
  type        = string
  default     = "global"
}
