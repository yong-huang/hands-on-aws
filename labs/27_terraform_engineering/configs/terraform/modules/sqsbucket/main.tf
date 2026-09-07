variable "name" { type = string }
variable "env"  { type = string }

resource "aws_s3_bucket" "b" {
  bucket = "${var.name}-bucket-${var.env}"
  tags   = { Env = var.env, Module = "sqsbucket" }
}

resource "aws_sqs_queue" "q" {
  name = "${var.name}-queue-${var.env}"
  tags = { Env = var.env, Module = "sqsbucket" }
}

output "bucket"   { value = aws_s3_bucket.b.id }
output "queue"    { value = aws_sqs_queue.q.name }
