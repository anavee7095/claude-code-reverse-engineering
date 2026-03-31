# =============================================================================
# Variables
# =============================================================================

# --- General ---

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "claude-code"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

# --- Network ---

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (ECS, Lambda)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for isolated database subnets"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

# --- Compute (ECS) ---

variable "api_container_image" {
  description = "Docker image URI for the API gateway container"
  type        = string
  default     = ""
}

variable "api_cpu" {
  description = "CPU units for API task (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 1024
}

variable "api_memory" {
  description = "Memory (MB) for API task"
  type        = number
  default     = 2048
}

variable "api_desired_count" {
  description = "Desired number of API task instances"
  type        = number
  default     = 2
}

variable "api_min_count" {
  description = "Minimum number of API task instances"
  type        = number
  default     = 2
}

variable "api_max_count" {
  description = "Maximum number of API task instances"
  type        = number
  default     = 20
}

variable "api_port" {
  description = "Port the API container listens on"
  type        = number
  default     = 3100
}

# --- Database (RDS) ---

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "claude_code"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "claude_admin"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for RDS"
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Number of days to retain RDS backups"
  type        = number
  default     = 7
}

variable "db_create_read_replica" {
  description = "Create a read replica for the database"
  type        = bool
  default     = false
}

# --- Cache (ElastiCache) ---

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes"
  type        = number
  default     = 1
}

# --- Storage (S3) ---

variable "session_retention_days" {
  description = "Days to retain session data in S3 before archiving"
  type        = number
  default     = 365
}

# --- Auth (Cognito) ---

variable "cognito_callback_urls" {
  description = "Allowed callback URLs for Cognito"
  type        = list(string)
  default     = ["http://localhost:14232/callback"]
}

variable "cognito_logout_urls" {
  description = "Allowed logout URLs for Cognito"
  type        = list(string)
  default     = ["http://localhost:14232/logout"]
}

# --- LLM ---

variable "llm_provider" {
  description = "LLM provider (anthropic, bedrock, azure, local)"
  type        = string
  default     = "anthropic"
  validation {
    condition     = contains(["anthropic", "bedrock", "azure", "local"], var.llm_provider)
    error_message = "LLM provider must be one of: anthropic, bedrock, azure, local."
  }
}

variable "anthropic_api_key" {
  description = "Anthropic API key (stored in Secrets Manager)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "default_model" {
  description = "Default LLM model for inference"
  type        = string
  default     = "claude-sonnet-4-20250514"
}

# --- Lambda ---

variable "lambda_memory_bash" {
  description = "Memory (MB) for Bash executor Lambda"
  type        = number
  default     = 2048
}

variable "lambda_timeout_bash" {
  description = "Timeout (seconds) for Bash executor Lambda"
  type        = number
  default     = 300
}

variable "lambda_memory_file_ops" {
  description = "Memory (MB) for file operations Lambda"
  type        = number
  default     = 1024
}

variable "lambda_provisioned_concurrency" {
  description = "Provisioned concurrency for tool Lambdas (0 = none)"
  type        = number
  default     = 0
}

# --- Monitoring ---

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring (additional cost)"
  type        = bool
  default     = false
}

# --- Domain ---

variable "domain_name" {
  description = "Custom domain name (e.g., api.claude-code.example.com)"
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS"
  type        = string
  default     = ""
}
