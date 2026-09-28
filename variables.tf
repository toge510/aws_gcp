variable "gcp_project_id" {
  description = "Cloud SQL と Workload Identity プールを作成する GCP プロジェクト ID"
  type        = string
}

variable "gcp_region" {
  description = "Cloud SQL を作成するリージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "aws_region" {
  description = "ECS Fargate を起動する AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "各リソース名のプレフィックス"
  type        = string
  default     = "aws-to-cloudsql"
}

####################################################################
# GCP: サービスアカウント / Cloud SQL
####################################################################

variable "sa_account_id" {
  description = <<-EOT
    Cloud SQL に接続するサービスアカウントの account_id。
    MySQL の IAM ユーザー名は "<account_id>@<project_id>.iam" となり、
    MySQL のユーザー名上限 32 文字に収める必要があるため短く保つこと。
  EOT
  type        = string
  default     = "sql-client"
}

variable "db_tier" {
  description = "Cloud SQL のマシンタイプ"
  type        = string
  default     = "db-f1-micro"
}

variable "db_version" {
  description = "Cloud SQL for MySQL のバージョン"
  type        = string
  default     = "MYSQL_8_0"
}

variable "db_name" {
  description = "作成するデータベース名"
  type        = string
  default     = "appdb"
}

variable "deletion_protection" {
  description = "Cloud SQL インスタンスの削除保護"
  type        = bool
  default     = false
}

####################################################################
# AWS: ネットワーク
####################################################################

variable "vpc_cidr" {
  description = "新規作成する VPC の CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = "使用するアベイラビリティゾーン数"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count は 1〜3 を指定してください。"
  }
}

####################################################################
# AWS: ECS Fargate
####################################################################

variable "task_cpu" {
  description = "Fargate タスクの CPU ユニット"
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Fargate タスクのメモリ (MiB)"
  type        = string
  default     = "1024"
}

variable "desired_count" {
  description = "ECS サービスのタスク数"
  type        = number
  default     = 1
}

variable "proxy_image" {
  description = "Cloud SQL Auth Proxy (v2) のコンテナイメージ"
  type        = string
  default     = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数"
  type        = number
  default     = 14
}
