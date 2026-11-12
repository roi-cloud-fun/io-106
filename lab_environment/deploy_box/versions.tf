###############################################################################
# IO-106 AWS Network Architecture -- deploy_box / versions.tf
#
# The per-student deploy box. This module is applied by the INSTRUCTOR, once,
# before class. It is deliberately separate from lab_env_student/ because:
#
#   - the deploy box is what RUNS terraform against lab_env_student/, so it has
#     to exist first and must survive `terraform destroy` of the student stack;
#   - students must never hold state for it.
#
# Per courses/.../CLAUDE.md "Lab delivery: per-student EC2 deploy box":
# SSM Session Manager only -- no SSH, no key pair, no public IP.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Course      = "IO-106"
      Environment = "training"
      ManagedBy   = "terraform"
      Component   = "deploy-box"
    }
  }
}
