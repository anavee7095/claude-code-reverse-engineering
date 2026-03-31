# =============================================================================
# Monitoring - CloudWatch Dashboards, Alarms, SNS
# =============================================================================

# --- SNS Topic for Alarms ---

resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-alarms"

  tags = {
    Name = "${local.name_prefix}-alarms-topic"
  }
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- CloudWatch Dashboard ---

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Service Health
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ECS Service - CPU & Memory"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.api.name, { stat = "Average" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.api.name, { stat = "Average" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ALB - Request Count & Latency"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p95" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ALB - Error Rates"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },

      # Row 2: Database & Cache
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "RDS - CPU & Connections"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Maximum" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "RDS - Storage & IOPS"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }],
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }],
            ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "ElastiCache - CPU & Memory"
          metrics = [
            ["AWS/ElastiCache", "CPUUtilization", "CacheClusterId", aws_elasticache_cluster.main.cluster_id, { stat = "Average" }],
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", aws_elasticache_cluster.main.cluster_id, { stat = "Average" }],
            ["AWS/ElastiCache", "CurrConnections", "CacheClusterId", aws_elasticache_cluster.main.cluster_id, { stat = "Maximum" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },

      # Row 3: Lambda & Custom Metrics
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - Invocations & Errors"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.bash_executor.function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.bash_executor.function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.file_operations.function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.file_operations.function_name, { stat = "Sum" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - Duration"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.bash_executor.function_name, { stat = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.bash_executor.function_name, { stat = "p95" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.bash_executor.function_name, { stat = "p99" }],
          ]
          period = 300
          region = local.region
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Custom - Active Sessions & Token Usage"
          metrics = [
            ["ClaudeCode", "ActiveSessions", { stat = "Maximum" }],
            ["ClaudeCode", "InputTokens", { stat = "Sum" }],
            ["ClaudeCode", "OutputTokens", { stat = "Sum" }],
          ]
          period = 3600
          region = local.region
          view   = "timeSeries"
        }
      },
    ]
  })
}

# --- CloudWatch Alarms ---

# High CPU on ECS
resource "aws_cloudwatch_metric_alarm" "ecs_high_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-high-cpu"
  alarm_description   = "ECS API service CPU utilization > 80% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-ecs-high-cpu-alarm"
  }
}

# High error rate on ALB
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${local.name_prefix}-alb-5xx-errors"
  alarm_description   = "ALB 5xx error count > 50 in 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 50

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-alb-5xx-alarm"
  }
}

# High latency on ALB
resource "aws_cloudwatch_metric_alarm" "alb_high_latency" {
  alarm_name          = "${local.name_prefix}-alb-high-latency"
  alarm_description   = "ALB P95 latency > 5 seconds for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p95"
  threshold           = 5

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-alb-high-latency-alarm"
  }
}

# RDS high CPU
resource "aws_cloudwatch_metric_alarm" "rds_high_cpu" {
  alarm_name          = "${local.name_prefix}-rds-high-cpu"
  alarm_description   = "RDS CPU > 80% for 15 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-rds-high-cpu-alarm"
  }
}

# RDS low storage
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${local.name_prefix}-rds-low-storage"
  alarm_description   = "RDS free storage < 10 GB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240  # 10 GB in bytes

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-rds-low-storage-alarm"
  }
}

# Lambda high error rate
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-lambda-errors"
  alarm_description   = "Lambda tool errors > 50 per minute"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 50

  dimensions = {
    FunctionName = aws_lambda_function.bash_executor.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-lambda-errors-alarm"
  }
}

# Redis high memory
resource "aws_cloudwatch_metric_alarm" "redis_high_memory" {
  alarm_name          = "${local.name_prefix}-redis-high-memory"
  alarm_description   = "ElastiCache memory > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    CacheClusterId = aws_elasticache_cluster.main.cluster_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name = "${local.name_prefix}-redis-high-memory-alarm"
  }
}
