# ho09 · Terraform 定义：S3 + SQS + SNS（tflocal 自动注入 LocalStack 端点）
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "env" {
  description = "环境标签，增量更新演示时从 dev 改为 prod"
  type        = string
  default     = "dev"
}

resource "aws_s3_bucket" "data" {
  bucket = "ho09-tf-data"
  tags = {
    Env     = var.env
    Managed = "terraform"
  }
}

resource "aws_sqs_queue" "jobs" {
  name         = "ho09-tf-jobs"
  delay_seconds = 0 # 增量更新演示：改为 5
}

resource "aws_sns_topic" "events" {
  name = "ho09-tf-events"
}

output "bucket_name" {
  value = aws_s3_bucket.data.id
}
