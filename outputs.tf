output "workload_identity_pool" {
  description = "Workload Identity プール名"
  value       = google_iam_workload_identity_pool.aws.name
}

output "workload_identity_provider" {
  description = "Workload Identity プロバイダ名 (認証情報設定の audience の元)"
  value       = google_iam_workload_identity_pool_provider.aws.name
}

output "service_account_email" {
  description = "ECS タスクが借用する GCP サービスアカウント"
  value       = google_service_account.sql_client.email
}

output "trusted_aws_role_arn" {
  description = "GCP 側が信頼する AWS ロールの ARN (assumed-role 形式)"
  value       = local.assumed_role_arn
}

output "cloudsql_connection_name" {
  description = "Cloud SQL のインスタンス接続名"
  value       = google_sql_database_instance.mysql.connection_name
}

output "cloudsql_public_ip" {
  description = "Cloud SQL のパブリック IP"
  value       = google_sql_database_instance.mysql.public_ip_address
}

output "iam_db_user" {
  description = "IAM データベース認証で使用する MySQL ユーザー名 (パスワード不要)"
  value       = local.iam_db_user
}

output "nat_public_ip" {
  description = "Cloud SQL の承認済みネットワークに登録された送信元 IP"
  value       = aws_eip.nat.public_ip
}

output "ecs_cluster_name" {
  description = "ECS クラスタ名"
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.this.name
}

output "logs_command" {
  description = "タスクのログを確認するコマンド"
  value       = "aws logs tail ${aws_cloudwatch_log_group.task.name} --follow --region ${var.aws_region}"
}

output "db_admin_user" {
  description = "GRANT 実行用の管理ユーザー名 (アプリからは使用しない)"
  value       = google_sql_user.admin.name
}

output "db_admin_password" {
  description = "GRANT 実行用の管理ユーザーのパスワード"
  value       = random_password.admin.result
  sensitive   = true
}
