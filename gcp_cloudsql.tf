####################################################################
# Cloud SQL for MySQL
#   IAM データベース認証を有効化し、NAT Gateway の EIP のみを
#   承認済みネットワークに登録する。
####################################################################

resource "google_sql_database_instance" "mysql" {
  name                = "${var.name_prefix}-${random_id.suffix.hex}"
  database_version    = var.db_version
  region              = var.gcp_region
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = true

    # IAM データベース認証 (Cloud SQL Auth Proxy の --auto-iam-authn に必要)
    database_flags {
      name  = "cloudsql_iam_authentication"
      value = "on"
    }

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"

      # Fargate タスクの外向き通信は NAT Gateway の EIP に集約される
      authorized_networks {
        name  = "aws-fargate-nat"
        value = "${aws_eip.nat.public_ip}/32"
      }
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      start_time         = "19:00"
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.mysql.name
}

####################################################################
# IAM サービスアカウントを MySQL ユーザーとして登録
#   MySQL のユーザー名は SA のメールアドレスから
#   ".gserviceaccount.com" を除いたもの。
####################################################################

locals {
  iam_db_user = trimsuffix(google_service_account.sql_client.email, ".gserviceaccount.com")
}

resource "google_sql_user" "iam_sa" {
  name     = local.iam_db_user
  instance = google_sql_database_instance.mysql.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  lifecycle {
    precondition {
      condition     = length(local.iam_db_user) <= 32
      error_message = "MySQL のユーザー名は 32 文字以内である必要があります。現在: '${local.iam_db_user}' (${length(local.iam_db_user)} 文字)。var.sa_account_id を短くしてください。"
    }
  }
}

####################################################################
# 管理用ユーザー (パスワード認証)
#   IAM ユーザーには既定で権限が付与されないため、GRANT を実行する
#   ための管理者が必要。アプリケーションからは使用しない。
####################################################################

resource "random_password" "admin" {
  length  = 24
  special = true
  # MySQL クライアントでエスケープが不要な記号のみ
  override_special = "-_=+"
}

resource "google_sql_user" "admin" {
  name     = "dbadmin"
  instance = google_sql_database_instance.mysql.name
  password = random_password.admin.result
  host     = "%"
}
