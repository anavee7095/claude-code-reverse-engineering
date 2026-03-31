# =============================================================================
# Database - RDS PostgreSQL
# =============================================================================

# --- RDS Parameter Group ---

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name_prefix}-pg16-"
  family      = "postgres16"
  description = "Custom parameter group for Claude Code"

  parameter {
    name  = "max_connections"
    value = "200"
  }

  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/4}"
    # 25% of instance memory, auto-calculated
  }

  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory*3/4}"
    # 75% of instance memory
  }

  parameter {
    name  = "work_mem"
    value = "16384"
    # 16 MB
  }

  parameter {
    name  = "maintenance_work_mem"
    value = "262144"
    # 256 MB
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
    # Log queries taking > 1 second
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${local.name_prefix}-db-params"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- RDS Instance ---

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"

  engine               = "postgres"
  engine_version       = "16.2"
  instance_class       = var.db_instance_class
  allocated_storage    = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 2  # Autoscaling
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  backup_retention_period = var.db_backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = var.enable_detailed_monitoring ? 60 : 0
  monitoring_role_arn = var.enable_detailed_monitoring ? aws_iam_role.rds_monitoring[0].arn : null

  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name_prefix}-final-snapshot" : null

  copy_tags_to_snapshot = true

  tags = {
    Name = "${local.name_prefix}-postgres"
  }
}

# --- Read Replica (Optional) ---

resource "aws_db_instance" "read_replica" {
  count = var.db_create_read_replica ? 1 : 0

  identifier          = "${local.name_prefix}-postgres-replica"
  replicate_source_db = aws_db_instance.main.identifier

  instance_class    = var.db_instance_class
  storage_encrypted = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  skip_final_snapshot = true

  tags = {
    Name = "${local.name_prefix}-postgres-replica"
  }
}

# --- RDS Enhanced Monitoring Role (Optional) ---

resource "aws_iam_role" "rds_monitoring" {
  count = var.enable_detailed_monitoring ? 1 : 0

  name = "${local.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.enable_detailed_monitoring ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- ElastiCache Redis ---

resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${local.name_prefix}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_nodes      = var.redis_num_cache_nodes
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  snapshot_retention_limit = var.environment == "prod" ? 3 : 0
  snapshot_window          = "02:00-03:00"
  maintenance_window       = "sun:03:00-sun:04:00"

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "${local.name_prefix}-redis-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  parameter {
    name  = "timeout"
    value = "300"
  }

  tags = {
    Name = "${local.name_prefix}-redis-params"
  }
}
