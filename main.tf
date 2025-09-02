#############################################
# Terraform: Lambda + CloudFront Deployment #
#############################################
#
# This configuration:
#  - Builds and packages the todo-list Lambda (TypeScript project in this directory)
#  - Deploys the Lambda with a Function URL
#  - Fronts the Lambda Function URL with a CloudFront distribution
#
# Assumptions:
#  - You are running Terraform from within: actions-in-aws/todo-list
#  - Node.js + npm are available locally (for build step)
#  - DATABASE_URL points at a reachable PostgreSQL instance
#
# Usage (typical local flow):
#   export AWS_REGION=us-east-1
#   export TF_VAR_database_url="postgres://user:pass@host:5432/db"
#   terraform init
#   terraform apply
#
# The build step (null_resource.build) will:
#   - Install production dependencies (npm install --omit=dev)
#   - Run the TypeScript build (npm run build)
#   - Stage only the runtime artifacts into ./lambda_build
#   - (Re)create a deployment zip via data.archive_file.lambda
#
# NOTE: For larger production systems you may prefer:
#   - CI pipeline to produce the zip artifact
#   - Using S3 object for Lambda code (instead of direct file upload)
#   - Separate state / workspace management
#
# CloudFront:
#  - No custom domain / ACM cert configured here (uses default *.cloudfront.net)
#  - Caching disabled (dynamic API). Adjust TTLs or add cache policies if desired.
#
# Security:
#  - Lambda Function URL is public (authorization_type = "NONE") but effectively shielded
#    by CloudFront when you only expose the CloudFront domain externally. For strict
#    access, add an origin custom header + Lambda@Edge or WAF rules.
#
# ==============================
# Provider & Required Versions
# ==============================

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
  }
}

#####################
# Configuration Vars
#####################

variable "aws_region" {
  type        = string
  description = "AWS region for deployment"
  default     = "us-east-1"
}

variable "database_url" {
  type        = string
  description = "PostgreSQL connection string for the todo-list Lambda"
  sensitive   = true
}

# Optionally allow overriding memory/timeout.
variable "lambda_memory_mb" {
  type        = number
  description = "Lambda memory size (MB)"
  default     = 256
}

variable "lambda_timeout_sec" {
  type        = number
  description = "Lambda timeout in seconds"
  default     = 10
}

provider "aws" {
  region = var.aws_region
}

###############################
# Build & Package (Local Exec)
###############################
#
# This null_resource performs the local build. Each change to source files (src/*.ts),
# package.json, or package-lock.json triggers a rebuild and new archive.
#
# If you prefer to build externally (CI), remove this block and supply your own zip.

locals {
  # Hash of all TypeScript sources to trigger rebuild.
  sources_hash = sha256(join(
    "",
    [
      for f in fileset(path.module, "src/**/*.ts") :
      filesha256("${path.module}/${f}")
    ]
  ))
  package_lock_hash = try(filesha256("${path.module}/package-lock.json"), "")
  package_json_hash = filesha256("${path.module}/package.json")
  build_trigger     = sha256(join("", [local.sources_hash, local.package_json_hash, local.package_lock_hash]))
}

resource "null_resource" "build" {
  triggers = {
    build_id = local.build_trigger
  }

  # You can replace this with a script (e.g., ./scripts/build.sh) if preferred.
  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -euo pipefail
      echo "[BUILD] Installing production dependencies..."
      npm install --omit=dev
      echo "[BUILD] Compiling TypeScript..."
      npm run build
      echo "[BUILD] Staging artifact..."
      rm -rf lambda_build
      mkdir -p lambda_build
      cp -R dist lambda_build/
      cp -R node_modules lambda_build/
      cp package.json lambda_build/
      # Optional: include any native modules / additional assets if needed
      echo "[BUILD] Build stage complete."
    EOT
  }
}

data "archive_file" "lambda" {
  depends_on  = [null_resource.build]
  type        = "zip"
  source_dir  = "${path.module}/lambda_build"
  output_path = "${path.module}/lambda.zip"
}

#################
# IAM For Lambda
#################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "todo-list-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Execution role for the todo-list Lambda"
}

# Basic logging policy attachment.
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

#####################
# Lambda Deployment
#####################

resource "aws_lambda_function" "todo" {
  function_name = "todo-list-api"
  description   = "Serverless TODO list API (Drizzle + PostgreSQL)"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "dist/handler.handler"
  runtime       = "nodejs18.x"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_sec
  publish       = true

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      DATABASE_URL = var.database_url
      # Add other environment variables as needed
    }
  }

  # Optional concurrency controls:
  # reserved_concurrent_executions = 10
  lifecycle {
    ignore_changes = [
      # Ignore runtime patch updates (if AWS auto-patches)
    ]
  }
}

#########################
# Public Function URL
#########################
# Used as the origin for CloudFront.
# NOTE: If you want to restrict direct access, consider:
#  - Setting up a CloudFront origin custom header and rejecting requests
#    without that header in the Lambda code (authorization layer)
#  - Or moving behind API Gateway for advanced routing/auth.

resource "aws_lambda_function_url" "todo" {
  function_name      = aws_lambda_function.todo.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "PATCH", "DELETE", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 3600
  }
}

#############################
# CloudFront Distribution
#############################
# Points to the Lambda Function URL. Caching is effectively disabled
# to ensure real-time API behavior.

locals {
  lambda_function_url_domain = replace(aws_lambda_function_url.todo.function_url, "https://", "")
}

resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  name                              = "todo-lambda-oac"
  description                       = "OAC placeholder (not strictly required for function URL)"
  origin_access_control_origin_type = "custom"
  signing_behavior                  = "never"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "api" {
  enabled             = true
  comment             = "CloudFront distribution for todo-list Lambda"
  price_class         = "PriceClass_100"
  default_root_object = ""
  http_version        = "http2"
  is_ipv6_enabled     = true

  origin {
    origin_id   = "todo-lambda-origin"
    domain_name = local.lambda_function_url_domain

    custom_origin_config {
      http_port              = 443
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    origin_access_control_id = aws_cloudfront_origin_access_control.lambda_oac.id
  }

  default_cache_behavior {
    target_origin_id       = "todo-lambda-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # Legacy forwarding configuration (simpler for demo). In production prefer custom cache/origin request policies.
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

############
# Outputs
############

output "lambda_function_name" {
  description = "Deployed Lambda function name"
  value       = aws_lambda_function.todo.function_name
}

output "lambda_function_version" {
  description = "Published Lambda function version"
  value       = aws_lambda_function.todo.version
}

output "lambda_function_url" {
  description = "Direct Lambda Function URL (public). Prefer using CloudFront domain."
  value       = aws_lambda_function_url.todo.function_url
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain for the API"
  value       = aws_cloudfront_distribution.api.domain_name
}

output "api_base_url" {
  description = "Base HTTPS URL for invoking the API through CloudFront"
  value       = "https://${aws_cloudfront_distribution.api.domain_name}"
}

############################################
# Post-Apply Test (example curl commands):
#
#   CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
#   curl https://$CF_DOMAIN/health
#   curl -X POST -H 'Content-Type: application/json' \
#        -d '{"text":"Hello"}' https://$CF_DOMAIN/todos
#   curl https://$CF_DOMAIN/todos
#
# (Expect JSON responses as defined in the handler.)
############################################
