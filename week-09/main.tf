terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Looks up the ECR repo you created in Step 3, so you never paste an account ID.
data "aws_ecr_repository" "property_api" {
  name = "property-api"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name            = "training-vpc-w9"
  cidr            = "10.2.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.2.1.0/24", "10.2.2.0/24"]
  enable_nat_gateway = false
}

# ---------- Security group (see Concept 10) ----------
resource "aws_security_group" "property_api" {
  name        = "property-api-sg"
  description = "Allow PropertyLite traffic on 8080"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PropertyLite from anywhere (training only)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (needed to pull the image from ECR)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Logs (see Concept 11) ----------
resource "aws_cloudwatch_log_group" "property_api" {
  name              = "/ecs/property-api"
  retention_in_days = 7
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "training" {
  name = "training-cluster"
}

resource "aws_iam_role" "ecs_execution" {
  name = "ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "property_api" {
  family                   = "property-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "property-api"
    image     = "${data.aws_ecr_repository.property_api.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 8080, hostPort = 8080 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.property_api.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "property_api" {
  name            = "property-api-service"
  cluster         = aws_ecs_cluster.training.id
  task_definition = aws_ecs_task_definition.property_api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.property_api.id]
    assign_public_ip = true
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]
}