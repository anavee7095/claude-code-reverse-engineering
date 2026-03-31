# =============================================================================
# Storage - S3 Buckets
# =============================================================================

# --- Sessions Bucket ---

resource "aws_s3_bucket" "sessions" {
  bucket = "${local.name_prefix}-sessions-${local.account_id}"

  tags = {
    Name = "${local.name_prefix}-sessions"
  }
}

resource "aws_s3_bucket_versioning" "sessions" {
  bucket = aws_s3_bucket.sessions.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sessions" {
  bucket = aws_s3_bucket.sessions.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "sessions" {
  bucket = aws_s3_bucket.sessions.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "sessions" {
  bucket = aws_s3_bucket.sessions.id

  rule {
    id     = "session-lifecycle"
    status = "Enabled"

    filter {
      prefix = "sessions/"
    }

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    expiration {
      days = var.session_retention_days
    }
  }

  rule {
    id     = "exports-lifecycle"
    status = "Enabled"

    filter {
      prefix = "exports/"
    }

    expiration {
      days = 90
    }
  }

  rule {
    id     = "noncurrent-version-cleanup"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# No CORS configuration needed - bucket is accessed only from server side

# --- S3 Bucket Policy (restrict to VPC endpoint) ---

resource "aws_s3_bucket_policy" "sessions" {
  bucket = aws_s3_bucket.sessions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VPCEndpointOnly"
        Effect = "Deny"
        Principal = "*"
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.sessions.arn,
          "${aws_s3_bucket.sessions.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:sourceVpce" = aws_vpc_endpoint.s3.id
          }
          # Allow IAM roles (ECS task role) to bypass VPC restriction
          ArnNotLike = {
            "aws:PrincipalArn" = [
              aws_iam_role.ecs_task.arn,
              aws_iam_role.lambda_tool_execution.arn,
            ]
          }
        }
      }
    ]
  })
}

# --- Lambda Tool Execution IAM Role ---

resource "aws_iam_role" "lambda_tool_execution" {
  name = "${local.name_prefix}-lambda-tool-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-lambda-tool-exec-role"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_tool_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_tool" {
  name = "${local.name_prefix}-lambda-tool-policy"
  role = aws_iam_role.lambda_tool_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.sessions.arn}/sessions/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
      }
    ]
  })
}

# --- Lambda Functions (Tool Sandbox) ---

resource "aws_lambda_function" "bash_executor" {
  function_name = "${local.name_prefix}-bash-executor"
  role          = aws_iam_role.lambda_tool_execution.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout_bash
  memory_size   = var.lambda_memory_bash

  # Placeholder - actual code deployed via CI/CD
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  ephemeral_storage {
    size = 5120  # 5 GB
  }

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      WORKSPACE_DIR      = "/tmp/workspace"
      MAX_EXEC_TIME      = "120"
      S3_BUCKET          = aws_s3_bucket.sessions.id
      DATABASE_HOST      = aws_db_instance.main.address
    }
  }

  tags = {
    Name = "${local.name_prefix}-bash-executor"
  }
}

resource "aws_lambda_function" "file_operations" {
  function_name = "${local.name_prefix}-file-operations"
  role          = aws_iam_role.lambda_tool_execution.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = 60
  memory_size   = var.lambda_memory_file_ops

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.sessions.id
    }
  }

  tags = {
    Name = "${local.name_prefix}-file-operations"
  }
}

resource "aws_lambda_function" "mcp_bridge" {
  function_name = "${local.name_prefix}-mcp-bridge"
  role          = aws_iam_role.lambda_tool_execution.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = 30
  memory_size   = 512

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      REDIS_URL = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:${aws_elasticache_cluster.main.cache_nodes[0].port}"
    }
  }

  tags = {
    Name = "${local.name_prefix}-mcp-bridge"
  }
}

# --- Lambda Placeholder Archive ---

data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda-placeholder.zip"

  source {
    content  = "exports.handler = async () => ({ statusCode: 200, body: 'Placeholder - deploy via CI/CD' });"
    filename = "index.js"
  }
}

# --- Provisioned Concurrency (Optional) ---

resource "aws_lambda_provisioned_concurrency_config" "bash_executor" {
  count = var.lambda_provisioned_concurrency > 0 ? 1 : 0

  function_name                  = aws_lambda_function.bash_executor.function_name
  provisioned_concurrent_executions = var.lambda_provisioned_concurrency
  qualifier                      = aws_lambda_function.bash_executor.version
}
