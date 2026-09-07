terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

locals { env = terraform.workspace == "default" ? "dev" : terraform.workspace }

module "sqsbucket" {
  source = "./modules/sqsbucket"
  name   = "ho27-app"
  env    = local.env
}

module "snsdemo" {
  source = "./modules/snsdemo"
  name   = "ho27-app"
  env    = local.env
}

output "summary" {
  value = {
    env    = local.env
    bucket = module.sqsbucket.bucket
    queue  = module.sqsbucket.queue
    topic  = module.snsdemo.topic
  }
}
