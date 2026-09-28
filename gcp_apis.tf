locals {
  required_apis = [
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "sqladmin.googleapis.com",
    "compute.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.required_apis)

  project = var.gcp_project_id
  service = each.value

  # terraform destroy で API を無効化するとプロジェクト内の他リソースに影響するため無効化しない
  disable_on_destroy = false
}
