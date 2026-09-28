####################################################################
# ECS Fargate
#   タスクは 4 コンテナ構成:
#     1. config-init     : ADC 設定と IMDS シムを共有ボリュームへ配置
#     2. imds-shim       : EC2 IMDS 互換エンドポイントを 127.0.0.1 に公開
#     3. cloud-sql-proxy : Workload Identity 連携で Cloud SQL へ接続
#     4. app             : 127.0.0.1:3306 経由で MySQL にクエリ
####################################################################

locals {
  shim_port = 8169

  # Workload Identity 連携の認証情報設定 (外部アカウント)。
  # 鍵素材を含まないため機密情報ではない。
  # credential_source は EC2 IMDS ではなく同一タスク内のシムを指す。
  adc_config = {
    universe_domain    = "googleapis.com"
    type               = "external_account"
    audience           = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.aws.name}"
    subject_token_type = "urn:ietf:params:aws:token-type:aws4_request"
    token_url          = "https://sts.googleapis.com/v1/token"

    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.sql_client.email}:generateAccessToken"

    credential_source = {
      environment_id                 = "aws1"
      region_url                     = "http://127.0.0.1:${local.shim_port}/latest/meta-data/placement/availability-zone"
      url                            = "http://127.0.0.1:${local.shim_port}/latest/meta-data/iam/security-credentials"
      imdsv2_session_token_url       = "http://127.0.0.1:${local.shim_port}/latest/api/token"
      regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    }
  }

  shared_mount = {
    sourceVolume  = "shared"
    containerPath = "/shared"
    readOnly      = false
  }

  log_config = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.task.name
      "awslogs-region"        = var.aws_region
      "awslogs-stream-prefix" = "task"
    }
  }
}

resource "aws_cloudwatch_log_group" "task" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "shared"
  }

  container_definitions = jsonencode([
    ####################################################################
    # 1. config-init: 設定ファイルを共有ボリュームに書き出して終了
    ####################################################################
    {
      name      = "config-init"
      image     = "public.ecr.aws/docker/library/alpine:3.20"
      essential = false

      entryPoint = ["/bin/sh", "-c"]
      command = [
        join("; ", [
          "set -eu",
          "printf '%s' \"$ADC_JSON_B64\" | base64 -d > /shared/adc.json",
          "printf '%s' \"$SHIM_PY_B64\" | base64 -d > /shared/imds_shim.py",
          "echo 'config-init: wrote /shared/adc.json and /shared/imds_shim.py'",
        ])
      ]

      environment = [
        { name = "ADC_JSON_B64", value = base64encode(jsonencode(local.adc_config)) },
        { name = "SHIM_PY_B64", value = filebase64("${path.module}/files/imds_shim.py") },
      ]

      mountPoints      = [local.shared_mount]
      logConfiguration = local.log_config
    },

    ####################################################################
    # 2. imds-shim: ECS の認証情報を IMDS 互換形式で中継
    ####################################################################
    {
      name      = "imds-shim"
      image     = "public.ecr.aws/docker/library/python:3.12-alpine"
      essential = true

      entryPoint = ["python3", "-u"]
      command    = ["/shared/imds_shim.py"]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "SHIM_HOST", value = "127.0.0.1" },
        { name = "SHIM_PORT", value = tostring(local.shim_port) },
      ]

      mountPoints = [local.shared_mount]

      dependsOn = [
        { containerName = "config-init", condition = "SUCCESS" },
      ]

      healthCheck = {
        # 認証情報を実際に取得できるところまで確認する
        command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${local.shim_port}/latest/meta-data/iam/security-credentials/ecs-task-role || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 15
      }

      logConfiguration = local.log_config
    },

    ####################################################################
    # 3. cloud-sql-proxy: 127.0.0.1:3306 で MySQL を待ち受け
    ####################################################################
    {
      name      = "cloud-sql-proxy"
      image     = var.proxy_image
      essential = true

      command = [
        "--address=127.0.0.1",
        "--port=3306",
        "--auto-iam-authn", # パスワードの代わりに IAM トークンを使用
        "--structured-logs",
        "--exit-zero-on-sigterm",
        google_sql_database_instance.mysql.connection_name,
      ]

      environment = [
        # 外部アカウント認証情報。SA キーは含まれない。
        { name = "GOOGLE_APPLICATION_CREDENTIALS", value = "/shared/adc.json" },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      mountPoints = [merge(local.shared_mount, { readOnly = true })]

      dependsOn = [
        { containerName = "config-init", condition = "SUCCESS" },
        { containerName = "imds-shim", condition = "HEALTHY" },
      ]

      logConfiguration = local.log_config
    },

    ####################################################################
    # 4. app: 動作確認用に定期的にクエリを実行
    ####################################################################
    {
      name      = "app"
      image     = "public.ecr.aws/docker/library/mysql:8.4"
      essential = true

      entryPoint = ["/bin/sh", "-c"]
      command = [
        join("\n", [
          "set -eu",
          "echo 'app: waiting for cloud-sql-proxy...'",
          "i=0",
          "until mysql -h 127.0.0.1 -P 3306 -u \"$DB_USER\" -e 'SELECT 1' >/dev/null 2>&1; do",
          "  i=$((i+1))",
          "  if [ \"$i\" -ge 60 ]; then echo 'app: proxy did not become ready'; exit 1; fi",
          "  sleep 5",
          "done",
          "echo 'app: connected'",
          "while true; do",
          "  mysql -h 127.0.0.1 -P 3306 -u \"$DB_USER\" --table -e \"SELECT NOW() AS now, CURRENT_USER() AS connected_as; SHOW DATABASES;\"",
          "  sleep 60",
          "done",
        ])
      ]

      environment = [
        # IAM データベース認証のためパスワードは不要
        { name = "DB_USER", value = local.iam_db_user },
        { name = "DB_NAME", value = var.db_name },
      ]

      dependsOn = [
        { containerName = "cloud-sql-proxy", condition = "START" },
      ]

      logConfiguration = local.log_config
    },
  ])
}

resource "aws_ecs_service" "this" {
  name            = var.name_prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # デバッグ用に `aws ecs execute-command` を許可
  enable_execute_command = true

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false # 送信元 IP を NAT の EIP に固定するため
  }

  depends_on = [
    aws_nat_gateway.this,
    google_sql_user.iam_sa,
    google_service_account_iam_member.wif_impersonation,
    google_project_iam_member.cloudsql_client,
    google_project_iam_member.cloudsql_instance_user,
  ]
}
