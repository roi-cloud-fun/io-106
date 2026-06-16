###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / locals.tf
###############################################################################
#
# AVIATRIX DISCLAIMER (reusable note -- referenced from README.md and every
# lab brief in scenarios/README.md):
#
#   In this lab we use AWS Transit Gateway. In your environment this
#   hub-and-spoke transit is provided by Aviatrix (Aviatrix Transit Gateway /
#   Spoke Gateways) managed by the network team -- the concepts map directly,
#   the management plane differs.
#
# What that means for each resource you see below:
#   - aws_ec2_transit_gateway          == Aviatrix Transit Gateway (the hub)
#   - aws_ec2_transit_gateway_*_attachment == an Aviatrix Spoke Gateway peering
#   - the TGW route table / propagations == Aviatrix's centralized segmentation
#   - the VPC route tables / security groups == the AWS substrate Aviatrix programs
# The Aviatrix Controller is the management plane that builds these for you in
# production; here you build them by hand so you can see and troubleshoot them.
#
###############################################################################

locals {
  name_prefix = "io106-${var.student_id}"

  common_tags = {
    Course      = "IO-106"
    Student     = var.student_id
    Environment = "training"
    ManagedBy   = "terraform"
  }

  # Scenario flags -- each labN toggles exactly one real resource off/wrong.
  is_lab1 = var.scenario == "lab1" # spoke_a -> spoke_b route removed
  is_lab2 = var.scenario == "lab2" # network-operations role trust principal wrong
  is_lab3 = var.scenario == "lab3" # lab.internal zone not associated to spoke_a
  is_lab4 = var.scenario == "lab4" # spoke_b SG ingress + spoke_b return route removed

  # Interface endpoints that make SSM work privately (no NAT, no IGW).
  ssm_services = ["ssm", "ec2messages", "ssmmessages"]

  next_step = var.scenario == "healthy" ? "Healthy baseline deployed. Run ./verify.sh for the Lab 0 PASS/FAIL checks." : "Scenario ${var.scenario} active -- a fault is injected. Diagnose and fix per scenarios/README.md, then re-apply with -var scenario=healthy to confirm."
}
