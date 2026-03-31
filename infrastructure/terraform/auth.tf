# =============================================================================
# Authentication - Cognito User Pool
# =============================================================================

# --- User Pool ---

resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-users"

  # Sign-in configuration
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # MFA configuration
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Schema
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 255
    }
  }

  schema {
    name                = "plan"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 20
    }
  }

  schema {
    name                = "org_id"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 0
      max_length = 50
    }
  }

  # Email configuration
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # User pool add-ons
  user_pool_add_ons {
    advanced_security_mode = var.environment == "prod" ? "ENFORCED" : "OFF"
  }

  # Post-confirmation Lambda trigger
  lambda_config {
    post_confirmation = aws_lambda_function.post_confirmation.arn
  }

  # Deletion protection
  deletion_protection = var.environment == "prod" ? "ACTIVE" : "INACTIVE"

  tags = {
    Name = "${local.name_prefix}-user-pool"
  }
}

# --- User Pool Domain ---

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name_prefix}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# --- User Pool Client (CLI Application) ---

resource "aws_cognito_user_pool_client" "cli" {
  name         = "${local.name_prefix}-cli"
  user_pool_id = aws_cognito_user_pool.main.id

  # CLI is a public client (no client secret)
  generate_secret = false

  # Auth flows
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # OAuth configuration
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "openid",
    "profile",
    "email",
  ]
  supported_identity_providers = ["COGNITO"]

  callback_urls = var.cognito_callback_urls
  logout_urls   = var.cognito_logout_urls

  # Token validity
  access_token_validity  = 1     # 1 hour
  id_token_validity      = 1     # 1 hour
  refresh_token_validity = 30    # 30 days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Security
  prevent_user_existence_errors = "ENABLED"

  # Read/write attributes
  read_attributes = [
    "email",
    "email_verified",
    "custom:plan",
    "custom:org_id",
  ]

  write_attributes = [
    "email",
    "custom:plan",
    "custom:org_id",
  ]
}

# --- User Pool Client (Server-to-Server, for API gateway) ---

resource "aws_cognito_user_pool_client" "server" {
  name         = "${local.name_prefix}-server"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  explicit_auth_flows = [
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # No OAuth needed for server-to-server
  allowed_oauth_flows_user_pool_client = false

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"

  read_attributes  = ["email", "email_verified", "custom:plan", "custom:org_id"]
  write_attributes = ["custom:plan", "custom:org_id"]
}

# --- User Pool Groups ---

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "System administrators"
  precedence   = 1
}

resource "aws_cognito_user_group" "pro" {
  name         = "pro"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Pro plan users"
  precedence   = 10
}

resource "aws_cognito_user_group" "team" {
  name         = "team"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Team plan users"
  precedence   = 20
}

resource "aws_cognito_user_group" "enterprise" {
  name         = "enterprise"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Enterprise plan users"
  precedence   = 30
}

# --- Lambda Trigger for Post-Confirmation (Create Profile) ---

resource "aws_lambda_function" "post_confirmation" {
  function_name = "${local.name_prefix}-post-confirmation"
  role          = aws_iam_role.lambda_tool_execution.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      DATABASE_HOST = aws_db_instance.main.address
      DATABASE_NAME = var.db_name
    }
  }

  tags = {
    Name = "${local.name_prefix}-post-confirmation"
  }
}

resource "aws_lambda_permission" "cognito_post_confirmation" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.post_confirmation.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}
