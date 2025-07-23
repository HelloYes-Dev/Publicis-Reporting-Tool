terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables

variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "af-south-1" # Cape Town
}

variable "pg_admin_password" {
  description = "PostgreSQL administrator password"
  type        = string
  sensitive   = true
}

variable "lambda_s3_key" {
  description = "S3 key for the Lambda deployment package (zip file)"
  type        = string
}

variable "lambda_s3_bucket" {
  description = "S3 bucket where the Lambda deployment package is stored"
  type        = string
}

# Random Suffix for Uniqueness

resource "random_id" "unique_id" {
  byte_length = 4
}

# VPC & Networking

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "publicis-vpc"
    Project = "Publicis"
  }
}

resource "aws_subnet" "webapp" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = {
    Name = "webapp-subnet"
  }
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags = {
    Name = "db-subnet"
  }
}

# Security Groups

resource "aws_security_group" "lambda_sg" {
  name        = "lambda-sg"
  description = "Allow Lambda outbound"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lambda-sg"
  }
}

resource "aws_security_group" "db_sg" {
  name        = "db-sg"
  description = "Allow PostgreSQL from Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    description      = "PostgreSQL from Lambda"
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    security_groups  = [aws_security_group.lambda_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "db-sg"
  }
}

# S3 Buckets (App Storage & Vector Storage)

resource "aws_s3_bucket" "app_storage" {
  bucket = "publicis-app-storage-${random_id.unique_id.hex}"
  force_destroy = true
  tags = {
    Project = "Publicis"
    Purpose = "App file storage"
  }
}

resource "aws_s3_bucket" "vector_storage" {
  bucket = "publicis-vector-storage-${random_id.unique_id.hex}"
  force_destroy = true
  tags = {
    Project = "Publicis"
    Purpose = "AI vector storage"
  }
}

# AWS Secrets Manager

resource "aws_secretsmanager_secret" "pg_admin" {
  name = "publicis-pg-admin-password"
}

resource "aws_secretsmanager_secret_version" "pg_admin_version" {
  secret_id     = aws_secretsmanager_secret.pg_admin.id
  secret_string = var.pg_admin_password
}

# RDS PostgreSQL

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "publicis-db-subnet-group"
  subnet_ids = [aws_subnet.db.id]
}

resource "aws_db_instance" "pg" {
  identifier              = "publicis-pg-${random_id.unique_id.hex}"
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  db_name                 = "reportflow"
  username                = "pgadmin"
  password                = var.pg_admin_password
  db_subnet_group_name    = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  skip_final_snapshot     = true
  publicly_accessible     = false
  storage_encrypted       = true
  multi_az                = false
  tags = {
    Project = "Publicis"
    Purpose = "Reporting DB"
  }
}

# Lambda IAM Role & Policies

resource "aws_iam_role" "lambda_exec" {
  name = "lambda-exec-role-publicis"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_bedrock" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_rds" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

# Attach CloudWatch and X-Ray policies for Lambda monitoring
resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Lambda Function (Web/API App)

resource "aws_lambda_function" "webapp" {
  function_name = "publicis-webapp-${random_id.unique_id.hex}"
  s3_bucket     = var.lambda_s3_bucket
  s3_key        = var.lambda_s3_key
  handler       = "index.handler" 
  runtime       = "nodejs18.x"    
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 30
  memory_size   = 1024
  vpc_config {
    subnet_ids         = [aws_subnet.webapp.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  environment {
    variables = {
      DATABASE_URL           = "postgresql://pgadmin:${var.pg_admin_password}@${aws_db_instance.pg.address}:5432/reportflow"
      VECTOR_STORAGE_BUCKET  = aws_s3_bucket.vector_storage.bucket
      BEDROCK_REGION         = var.aws_region
    }
  }
  tracing_config {
    mode = "Active" 
  }
  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# API Gateway (HTTP API)

resource "aws_apigatewayv2_api" "webapp_api" {
  name          = "publicis-webapp-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.webapp_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webapp.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.webapp_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.webapp_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webapp.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webapp_api.execution_arn}/*/*"
}

# CloudFront & WAF

resource "aws_wafv2_web_acl" "web_acl" {
  name        = "publicis-waf"
  scope       = "CLOUDFRONT"
  default_action {
    allow {}
  }
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "waf-common"
      sampled_requests_enabled   = true
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "waf"
    sampled_requests_enabled   = true
  }
}

# S3 Bucket for Static Frontend Hosting

resource "aws_s3_bucket" "frontend" {
  bucket = "publicis-frontend-${random_id.unique_id.hex}"
  force_destroy = true
  tags = {
    Project = "Publicis"
    Purpose = "Static Frontend Hosting"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "frontend_policy" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = "*",
        Action = [
          "s3:GetObject"
        ],
        Resource = [
          "${aws_s3_bucket.frontend.arn}/*"
        ]
      }
    ]
  })
}

# CloudFront with S3 + API Gateway Origins

resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "frontend-oac"
  origin_access_control_origin_type  = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
  description                       = "OAC for S3 frontend bucket"
}

resource "aws_cloudfront_distribution" "webapp" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "frontend-s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.webapp_api.api_endpoint, "https://", "")
    origin_id   = "webapp-api-origin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend-s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "webapp-api-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }
  }

  price_class = "PriceClass_100"
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  web_acl_id = aws_wafv2_web_acl.web_acl.arn
  tags = {
    Project = "Publicis"
  }
}

# AWS Budgets

resource "aws_budgets_budget" "publicis_budget" {
  name              = "publicis-budget"
  budget_type       = "COST"
  limit_amount      = "1000"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  notification {
    comparison_operator = "GREATER_THAN"
    notification_type   = "ACTUAL"
    threshold           = 80
    threshold_type      = "PERCENTAGE"
    subscriber_email_addresses = ["ruttger@helloyes.co.za"]
  }
}

# Outputs

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "lambda_function_name" {
  description = "Lambda function name for the web/API app"
  value       = aws_lambda_function.webapp.function_name
}

output "apigateway_url" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.webapp_api.api_endpoint
}

output "cloudfront_url" {
  description = "CloudFront URL for the web/API app (serves both frontend and backend)"
  value       = aws_cloudfront_distribution.webapp.domain_name
}

output "s3_app_storage_bucket" {
  description = "S3 bucket for app storage"
  value       = aws_s3_bucket.app_storage.bucket
}

output "s3_vector_storage_bucket" {
  description = "S3 bucket for vector storage"
  value       = aws_s3_bucket.vector_storage.bucket
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.pg.address
}

output "bedrock_region" {
  description = "AWS region for Bedrock API"
  value       = var.aws_region
}

output "frontend_s3_bucket" {
  description = "S3 bucket for static frontend hosting"
  value       = aws_s3_bucket.frontend.bucket
}


