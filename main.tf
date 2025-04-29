terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ──────────────────────────────────────────────────────────────────────────────
# VARIABLES
# ──────────────────────────────────────────────────────────────────────────────
variable "region" {
  description = "AWS region"
  default     = "eu-north-1"
}

variable "account_id" {
  description = "Your AWS account ID"
}

variable "repo_name" {
  description = "ECR repository name"
  default     = "daily-video-renderer"
}

variable "s3_bucket" {
  description = "S3 bucket for daily videos"
  default     = "my-daily-videos-bucket-2025-umar"
}

variable "openai_api_key" {
  description = "Your OpenAI API key"
  type        = string
  sensitive   = true
}

variable "youtube_client_id" {
  description = "YouTube OAuth client_id"
  type        = string
  sensitive   = true
}
variable "youtube_client_secret" {
  description = "YouTube OAuth client_secret"
  type        = string
  sensitive   = true
}
variable "youtube_refresh_token" {
  description = "YouTube OAuth refresh_token"
  type        = string
  sensitive   = true
}

variable "lambda_zip_path" {
  description = "Path to the CI-generated youtube-uploader ZIP"
  type        = string
}
# ──────────────────────────────────────────────────────────────────────────────
# DATA SOURCES (default VPC/subnets/SG)
# ──────────────────────────────────────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}
data "aws_security_group" "default" {
  filter {
    name   = "group-name"
    values = ["default"]
  }
  vpc_id = data.aws_vpc.default.id
}
# ──────────────────────────────────────────────────────────────────────────────
# S3 BUCKET
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "videos" {
  bucket = var.s3_bucket
}
# ──────────────────────────────────────────────────────────────────────────────
# ECR
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "renderer" {
  name = var.repo_name
}
# ──────────────────────────────────────────────────────────────────────────────
# SECRETS MANAGER
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "openai" {
  name = "openai/${var.repo_name}"
}
resource "aws_secretsmanager_secret_version" "openai" {
  secret_id     = aws_secretsmanager_secret.openai.id
  secret_string = jsonencode({ OPENAI_API_KEY = var.openai_api_key })
}

resource "aws_secretsmanager_secret" "youtube" {
  name = "prod/YouTubeUploader/credentials"
}
resource "aws_secretsmanager_secret_version" "youtube" {
  secret_id     = aws_secretsmanager_secret.youtube.id
  secret_string = jsonencode({
    client_id     = var.youtube_client_id
    client_secret = var.youtube_client_secret
    refresh_token = var.youtube_refresh_token
    token_uri     = "https://oauth2.googleapis.com/token"
  })
}
# ──────────────────────────────────────────────────────────────────────────────
# IAM ROLES & POLICIES
# ──────────────────────────────────────────────────────────────────────────────
# ECS Task Role
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecs_task" {
  name               = "ecs-render-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}
resource "aws_iam_role_policy_attachment" "ecs_task_s3" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
resource "aws_iam_role_policy_attachment" "ecs_task_polly" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPollyFullAccess"
}
resource "aws_iam_role_policy_attachment" "ecs_task_secrets" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# ECS Execution Role
resource "aws_iam_role" "ecs_exec" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}
resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lambda Role
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda" {
  name               = "youtube-uploader-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}
resource "aws_iam_role_policy_attachment" "lambda_secrets" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.repo_name}"
  retention_in_days = 7
}
# ──────────────────────────────────────────────────────────────────────────────
# ECS CLUSTER & TASK DEFINITION
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "cluster" {
  name = "daily-renderer-cluster"
}
resource "aws_ecs_task_definition" "renderer" {
  family                   = "youtube"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "3072"
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "video-renderer"
    image     = "${aws_ecr_repository.renderer.repository_url}:latest"
    cpu       = 0
    memory    = 524
    essential = true

    environment = [{
      name      = "OPENAI_API_KEY"
      valueFrom = aws_secretsmanager_secret.openai.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "renderer"
        awslogs-create-group  = "true"
      }
    }
  }])
}
# RENDER SCHEDULE
resource "aws_cloudwatch_event_rule" "render" {
  name                = "daily-video-render"
  schedule_expression = "cron(50 6 * * ? *)"
}
resource "aws_cloudwatch_event_target" "render" {
  rule     = aws_cloudwatch_event_rule.render.name
  arn      = aws_ecs_cluster.cluster.arn
  role_arn = aws_iam_role.ecs_exec.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.renderer.arn
    launch_type         = "FARGATE"

    network_configuration {
      subnets         = data.aws_subnets.default.ids
      security_groups = [data.aws_security_group.default.id]
      assign_public_ip = "true"
    }
  }
}
# ──────────────────────────────────────────────────────────────────────────────
# LAMBDA UPLOAD FUNCTION
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "uploader" {
  function_name = "youtube-uploader"
  role          = aws_iam_role.lambda.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  filename      = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)
  memory_size   = 512
  timeout       = 300

  environment {
    variables = {
      S3_BUCKET   = aws_s3_bucket.videos.bucket
      SECRET_NAME = aws_secretsmanager_secret.youtube.name
    }
  }
}
resource "aws_cloudwatch_event_rule" "upload" {
  name                = "daily-video-upload"
  schedule_expression = "cron(0 7 * * ? *)"
}
resource "aws_cloudwatch_event_target" "upload" {
  rule       = aws_cloudwatch_event_rule.upload.name
  arn        = aws_lambda_function.uploader.arn
  target_id  = "uploader"
}
resource "aws_lambda_permission" "allow_event" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uploader.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.upload.arn
}

# ──────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ──────────────────────────────────────────────────────────────────────────────
output "ecs_cluster_id" {
  value = aws_ecs_cluster.cluster.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.renderer.repository_url
}