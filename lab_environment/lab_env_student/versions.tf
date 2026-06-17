###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / versions.tf
#
# Per-student, AWS-native network lab: a Transit VPC + AWS Transit Gateway
# (hub) with two spoke VPCs, SSM-managed test instances, centralized-style
# interface VPC endpoints, a Route53 private zone, VPC Flow Logs, and a
# cross-account-style network-operations IAM role. One `terraform apply`
# per student deploys the whole thing; `-var scenario=labN` injects one
# realistic fault the student diagnoses and fixes.
#
# AVIATRIX DISCLAIMER (repeated in locals.tf, README.md, and every lab brief):
#   In this lab we use AWS Transit Gateway. In your environment this
#   hub-and-spoke transit is provided by Aviatrix (Aviatrix Transit Gateway /
#   Spoke Gateways) managed by the network team -- the concepts map directly,
#   the management plane differs.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(local.common_tags, var.tags)
  }
}
