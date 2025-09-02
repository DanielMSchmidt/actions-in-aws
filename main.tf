#############################################
# Terraform: RDS Postgres + Lambda + CloudFront
#############################################
#
# This configuration:
#  - Creates an isolated VPC (no outbound Internet/NAT needed for the app)
#  - Provisions a PostgreSQL RDS instance inside private subnets
#  - Builds & deploys the todo-list Lambda (TypeScript project in this directory)
#  - Connects Lambda to the VPC with a security group allowing DB access
#  - Exposes the Lambda through a public Lambda Function URL
#  - Fronts that URL with a CloudFront distribution
#
# IMPORTANT (Non‑Production Caveats):
#  - No NAT Gateway / Internet access from private subnets (Lambda only talks to RDS).
#  - RDS is placed in private subnets and only accessible from the Lambda SG.
#  - For production you should add:
#       * Encrypted Secrets in AWS Secrets Manager
#       * Automated backups / PITR, Multi-AZ, enhanced monitoring
#       * Proper password rotation
#       * Logging / metrics dashboards
#       * WAF / auth in front of CloudFront
#
# Usage:
#   export TF_VAR_database_username="appuser"
#   export TF_VAR_database_name="todos"
#   terraform init
#   terraform apply \
#     -var="database_username=appuser" \
#     -var="database_name=todos"
#
# After apply:
#   CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
#   curl https://$CF_DOMAIN/health
#   curl -X POST -H 'Content-Type: application/json' \
#        -d '{"text":"Example"}' https://$CF_DOMAIN/todos
#
#############################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

#############################################
# Variables
#############################################

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for all resources."
}

variable "database_username" {
  type        = string
  description = "Master username for the Postgres database."
  default     = "demo"
}

variable "database_name" {
  type        = string
  description = "Initial database name to create."
  default     = "tododemo"
}

variable "database_instance_class" {
  type        = string
  default     = "db.t3.micro"
  description = "RDS instance class."
}

variable "database_allocated_storage_gb" {
  type        = number
  default     = 20
  description = "Allocated storage (GB) for RDS."
}

variable "lambda_memory_mb" {
  type        = number
  default     = 256
  description = "Lambda memory (MB)."
}

variable "lambda_timeout_sec" {
  type        = number
  default     = 10
  description = "Lambda timeout (seconds)."
}

# Set to true to skip final snapshot on destroy (safer for ephemeral/dev).
variable "skip_final_snapshot" {
  type        = bool
  default     = true
  description = "Whether to skip final snapshot upon RDS destruction (NOT recommended for prod)."
}

provider "aws" {
  region = var.aws_region
}

#############################################
# Random Password (avoid special chars that break URI easily)
#############################################

resource "random_password" "db" {
  length      = 24
  special     = false
  upper       = true
  lower       = true
  numeric     = true
  min_upper   = 3
  min_lower   = 5
  min_numeric = 3
}

#############################################
# Networking (Minimal VPC)
#############################################
#
# - 1 VPC
# - 2 private subnets (for DB + Lambda)
# - No NAT / IGW for simplicity
# - Security groups:
#     * lambda_sg: egress all
#     * db_sg: ingress 5432 from lambda_sg
#

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "todo-vpc" }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "todo-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false
  tags                    = { Name = "todo-private-b" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_db_subnet_group" "db" {
  name       = "todo-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags = {
    Name = "todo-db-subnets"
  }
}

resource "aws_security_group" "lambda" {
  name        = "todo-lambda-sg"
  description = "Security group for Lambda ENIs"
  vpc_id      = aws_vpc.main.id

  # Egress all (Lambda only needs to reach RDS internally)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "todo-lambda-sg" }
}

resource "aws_security_group" "db" {
  name        = "todo-db-sg"
  description = "Allow Postgres access from Lambda security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from Lambda SG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # (Optional) no outbound needed but AWS requires an egress rule if not using default SG
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "todo-db-sg" }
}

#############################################
# RDS PostgreSQL Instance
#############################################

resource "aws_db_instance" "todo" {
  identifier                 = "todo"
  engine                     = "postgres"
  instance_class             = var.database_instance_class
  allocated_storage          = var.database_allocated_storage_gb
  storage_encrypted          = true
  db_name                    = var.database_name
  username                   = var.database_username
  password                   = random_password.db.result
  port                       = 5432
  db_subnet_group_name       = aws_db_subnet_group.db.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  publicly_accessible        = false
  skip_final_snapshot        = var.skip_final_snapshot
  deletion_protection        = false
  apply_immediately          = true
  backup_retention_period    = 0
  auto_minor_version_upgrade = true

  # Consider performance_insights_enabled / monitoring_interval for production.

  tags = {
    Name = "todo-postgres"
  }
}

#############################################
# Build & Package Lambda (local exec)
#############################################
#
# Optimized build:
#  - Installs ONLY production dependencies (omit dev)
#  - Runs the bundled build (tsc + esbuild) producing a single dist/handler.js
#  - Removes all other compiled JS except handler.js to minimize artifact size
#  - Archives ONLY the minimal contents (no node_modules needed because esbuild inlines deps)
#

locals {
  # Hash all TypeScript source files inside the todo-list project
  sources_hash = sha256(join("", [
    for f in fileset("${path.module}/todo-list", "src/**/*.ts") : filesha256("${path.module}/todo-list/${f}")
  ]))
  package_json_hash = filesha256("${path.module}/todo-list/package.json")
  package_lock_hash = try(filesha256("${path.module}/todo-list/package-lock.json"), "")
  build_trigger = sha256(join("", [
    local.sources_hash,
    local.package_json_hash,
    local.package_lock_hash
  ]))
}

resource "null_resource" "build" {
  triggers = {
    build_id = local.build_trigger
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/todo-list"
    command     = <<-EOT
      set -euo pipefail
      echo "[BUILD] Installing dependencies"
      if [ -f package-lock.json ]; then
        npm ci || npm install
      else
        npm install
      fi

      echo "[BUILD] Bundling (tsc + esbuild)..."
      npm run build:lambda

      echo "[BUILD] Pruning dist to bundled handler only..."
      find dist -type f ! -name 'handler.js' -delete || true
      # Remove empty directories if any
      find dist -type d -empty -delete || true

      echo "[BUILD] Staging minimal lambda artifact..."
      rm -rf lambda_build
      mkdir -p lambda_build/dist
      cp dist/handler.js lambda_build/dist/
      # (Optional) retain sourcemap by uncommenting:
      # [ -f dist/handler.js.map ] && cp dist/handler.js.map lambda_build/dist/

      echo "[BUILD] Done. Contents:"
      find lambda_build -maxdepth 3 -type f -print
    EOT
  }
}

data "archive_file" "lambda_zip" {
  depends_on  = [null_resource.build]
  type        = "zip"
  source_dir  = "${path.module}/todo-list/lambda_build"
  output_path = "${path.module}/lambda.zip"
}

#############################################
# IAM Role & Policies
#############################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "todo-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  description        = "Execution role for todo-list Lambda."
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Added to allow Lambda functions configured for VPC access to manage ENIs
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

#############################################
# Lambda Function
#############################################

# Build the Postgres connection string for Lambda environment.
locals {
  database_connection_string = "postgres://${var.database_username}:${random_password.db.result}@${aws_db_instance.todo.address}:${aws_db_instance.todo.port}/${var.database_name}"
}

resource "aws_lambda_function" "todo" {
  function_name = "todo-list-api"
  description   = "Serverless TODO list API with Drizzle + RDS Postgres"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "dist/handler.handler"
  runtime       = "nodejs18.x"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_sec
  publish       = true

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DATABASE_URL = local.database_connection_string
    }
  }

  vpc_config {
    security_group_ids = [aws_security_group.lambda.id]
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  }

  depends_on = [aws_db_instance.todo]
}

#############################################
# Lambda Function URL
#############################################

resource "aws_lambda_function_url" "todo" {
  function_name      = aws_lambda_function.todo.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "PATCH", "DELETE"]
    allow_origins     = ["*"]
    max_age           = 3600
  }
}

#############################################
# CloudFront Distribution (Origin = Lambda Function URL)
#############################################

locals {
  lambda_function_url_domain = trimsuffix(replace(aws_lambda_function_url.todo.function_url, "https://", ""), "/")
}

resource "aws_cloudfront_distribution" "api" {
  enabled         = true
  comment         = "CloudFront for todo-list Lambda"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true
  http_version    = "http2"

  origin {
    origin_id   = "todo-lambda-origin"
    domain_name = local.lambda_function_url_domain

    custom_origin_config {
      http_port              = 443
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "todo-lambda-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 1
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  depends_on = [aws_lambda_function.todo]
}

#############################################
# Outputs
#############################################

output "database_endpoint" {
  description = "RDS endpoint (host:port)."
  value       = aws_db_instance.todo.address
}

output "database_name" {
  description = "Database name."
  value       = var.database_name
}

output "database_username" {
  description = "Database master username."
  value       = var.database_username
}

output "database_password" {
  description = "Database master password (sensitive)."
  value       = random_password.db.result
  sensitive   = true
}

output "database_connection_string" {
  description = "Postgres connection string used by Lambda (sensitive)."
  value       = local.database_connection_string
  sensitive   = true
}

output "lambda_function_name" {
  value       = aws_lambda_function.todo.function_name
  description = "Lambda function name."
}

output "lambda_function_version" {
  value       = aws_lambda_function.todo.version
  description = "Published version."
}

output "lambda_function_url" {
  value       = aws_lambda_function_url.todo.function_url
  description = "Direct Lambda Function URL."
}

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.api.domain_name
  description = "CloudFront domain to access the API."
}

output "api_base_url" {
  value       = "https://${aws_cloudfront_distribution.api.domain_name}"
  description = "Base CloudFront URL for the API."
}

#############################################
# Post-Apply Quick Test:
#
#   CF=$(terraform output -raw cloudfront_domain_name)
#   curl https://$CF/health
#   curl -X POST -H 'Content-Type: application/json' \
#        -d '{"text":"Test"}' https://$CF/todos
#   curl https://$CF/todos
#
#############################################
