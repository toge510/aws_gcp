####################################################################
# Workload Identity 連携 (AWS プロバイダ)
#   ECS タスクロールの一時認証情報で署名した GetCallerIdentity
#   リクエストを GCP STS に提示し、サービスアカウントを借用する。
#   サービスアカウントキーは一切不要。
####################################################################

resource "random_id" "suffix" {
  byte_length = 3
}

resource "google_iam_workload_identity_pool" "aws" {
  workload_identity_pool_id = "${var.name_prefix}-${random_id.suffix.hex}"
  display_name              = "AWS ECS pool"
  description               = "AWS ECS Fargate から Cloud SQL へキーレス接続するためのプール"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-provider"
  display_name                       = "AWS provider"

  aws {
    account_id = data.aws_caller_identity.current.account_id
  }

  attribute_mapping = {
    "google.subject"        = "assertion.arn"
    "attribute.aws_account" = "assertion.account"
    # assumed-role の ARN 形式に正規化する
    #   arn:aws:sts::123456789012:assumed-role/ROLE/i-0abc...
    #     -> arn:aws:sts::123456789012:assumed-role/ROLE
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }

  # 当該 ECS タスクロール以外からのトークン交換を拒否する
  attribute_condition = "attribute.aws_role == '${local.assumed_role_arn}'"
}

####################################################################
# 借用対象のサービスアカウント
####################################################################

resource "google_service_account" "sql_client" {
  account_id   = var.sa_account_id
  display_name = "Cloud SQL client for AWS ECS Fargate"

  depends_on = [google_project_service.this]
}

# Workload Identity プールの当該 AWS ロールにのみ借用を許可
resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.sql_client.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws.name}/attribute.aws_role/${local.assumed_role_arn}"
}

# Cloud SQL Auth Proxy による接続に必要
resource "google_project_iam_member" "cloudsql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.sql_client.email}"
}

# IAM データベース認証 (自動 IAM 認証) に必要
resource "google_project_iam_member" "cloudsql_instance_user" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.sql_client.email}"
}
