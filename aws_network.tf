####################################################################
# VPC
#   Fargate タスクはプライベートサブネットに配置し、外向き通信を
#   NAT Gateway の Elastic IP に集約する。この EIP を Cloud SQL の
#   承認済みネットワークに登録するため、送信元 IP が固定される。
#   (パブリック IP 直付けでは IP が固定できず承認済みネットワークに
#    登録できない)
####################################################################

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name_prefix }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name_prefix }
}

resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)

  tags = { Name = "${var.name_prefix}-public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value + 100)

  tags = { Name = "${var.name_prefix}-private-${each.key}" }
}

####################################################################
# NAT Gateway (送信元 IP を固定するため単一構成)
####################################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name_prefix}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = { Name = var.name_prefix }

  depends_on = [aws_internet_gateway.this]
}

####################################################################
# ルーティング
####################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

####################################################################
# セキュリティグループ
#   インバウンドは不要 (Cloud SQL へはタスクからの片方向接続のみ)。
#   Cloud SQL Auth Proxy は 127.0.0.1 で待ち受けるため、タスク内
#   コンテナ間通信は SG の対象外。
####################################################################

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-task"
  description = "Fargate task egress only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-task" }
}

resource "aws_vpc_security_group_egress_rule" "task_all" {
  security_group_id = aws_security_group.task.id
  description       = "Allow all outbound (Cloud SQL / ECR / STS)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
