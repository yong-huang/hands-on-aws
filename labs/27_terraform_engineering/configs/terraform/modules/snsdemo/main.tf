variable "name" { type = string }
variable "env"  { type = string }

resource "aws_sns_topic" "t" {
  name = "${var.name}-topic-${var.env}"
  tags = { Env = var.env, Module = "snsdemo" }
}

output "topic" { value = aws_sns_topic.t.name }
