# =============================================================================
# Outputs
# =============================================================================

# --- Network ---

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

# --- Compute ---

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS API service name"
  value       = aws_ecs_service.api.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for API container"
  value       = aws_ecr_repository.api.repository_url
}

output "alb_dns_name" {
  description = "ALB DNS name (use this to access the API)"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route53 alias records)"
  value       = aws_lb.main.zone_id
}

output "api_url" {
  description = "Full API URL"
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"
}

# --- Database ---

output "rds_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "RDS hostname"
  value       = aws_db_instance.main.address
}

output "rds_read_replica_endpoint" {
  description = "RDS read replica endpoint"
  value       = var.db_create_read_replica ? aws_db_instance.read_replica[0].endpoint : "N/A"
}

output "database_url_secret_arn" {
  description = "ARN of the database URL secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db_url.arn
}

# --- Cache ---

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = "${aws_elasticache_cluster.main.cache_nodes[0].address}:${aws_elasticache_cluster.main.cache_nodes[0].port}"
}

# --- Storage ---

output "sessions_bucket_name" {
  description = "S3 bucket name for session storage"
  value       = aws_s3_bucket.sessions.id
}

output "sessions_bucket_arn" {
  description = "S3 bucket ARN for session storage"
  value       = aws_s3_bucket.sessions.arn
}

# --- Auth ---

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "Cognito CLI App Client ID"
  value       = aws_cognito_user_pool_client.cli.id
}

output "cognito_domain" {
  description = "Cognito hosted UI domain"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com"
}

output "cognito_auth_url" {
  description = "Full Cognito authorization URL for CLI"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com/oauth2/authorize?response_type=code&client_id=${aws_cognito_user_pool_client.cli.id}&redirect_uri=http://localhost:14232/callback&scope=openid+profile+email"
}

# --- Lambda ---

output "lambda_bash_executor_arn" {
  description = "Bash executor Lambda ARN"
  value       = aws_lambda_function.bash_executor.arn
}

output "lambda_file_operations_arn" {
  description = "File operations Lambda ARN"
  value       = aws_lambda_function.file_operations.arn
}

output "lambda_mcp_bridge_arn" {
  description = "MCP bridge Lambda ARN"
  value       = aws_lambda_function.mcp_bridge.arn
}

# --- Secrets ---

output "anthropic_api_key_secret_arn" {
  description = "ARN of the Anthropic API key secret"
  value       = aws_secretsmanager_secret.anthropic_api_key.arn
}

output "jwt_secret_arn" {
  description = "ARN of the JWT secret"
  value       = aws_secretsmanager_secret.jwt_secret.arn
}

# --- Monitoring ---

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "sns_alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = aws_sns_topic.alarms.arn
}

# --- Summary ---

output "deployment_summary" {
  description = "Summary of deployed resources"
  value = <<-EOT

    ========================================
    Claude Code Clone - Infrastructure Summary
    ========================================

    Environment: ${var.environment}
    Region:      ${local.region}

    API Endpoint: ${var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"}
    ECR Repo:     ${aws_ecr_repository.api.repository_url}

    Database:     ${aws_db_instance.main.address}:5432/${var.db_name}
    Redis:        ${aws_elasticache_cluster.main.cache_nodes[0].address}:${aws_elasticache_cluster.main.cache_nodes[0].port}
    S3 Bucket:    ${aws_s3_bucket.sessions.id}

    Auth Domain:  ${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com
    Client ID:    ${aws_cognito_user_pool_client.cli.id}

    Dashboard:    https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}

    Next Steps:
    1. Build and push container:  docker build -t ${aws_ecr_repository.api.repository_url}:latest .
    2. Store Anthropic API key:   aws secretsmanager put-secret-value --secret-id ${aws_secretsmanager_secret.anthropic_api_key.id} --secret-string "sk-ant-..."
    3. Run DB migrations:         aws ecs run-task --cluster ${aws_ecs_cluster.main.name} --task-definition ${local.name_prefix}-migrate ...
    4. Test:                      curl ${var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"}/health
    ========================================
  EOT
}
