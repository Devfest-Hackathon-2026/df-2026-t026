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

variable "passcode" {
  description = "API の合言葉（アプリで入力する）。HTTP ヘッダーで送るので英数字・ハイフン・下線だけにする"
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{10,}$", var.passcode))
    error_message = "合言葉は英数字・ハイフン・下線で10文字以上にしてください"
  }
}

variable "billing_account" {
  description = "予算アラートを付ける課金アカウントの ID（gcloud billing accounts list で見られる）"
  type        = string
}

variable "budget_amount" {
  description = "1か月の予算。単位は課金アカウントの通貨（いまは円）"
  type        = number
  default     = 3000
}

variable "team_members" {
  description = "ローカルから本物の Gemini（Vertex AI）を呼べるようにするメンバーの Google アカウントのメールアドレス"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for m in var.team_members : can(regex("^[^@:\\s]+@[^@:\\s]+$", m))])
    error_message = "team_members にはメールアドレスだけを書いてください（user: は付けない）"
  }
}
