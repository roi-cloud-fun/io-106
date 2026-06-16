###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / outputs.tf
###############################################################################

output "region" {
  description = "AWS region of the stack."
  value       = var.region
}

output "account_id" {
  description = "AWS account ID (the network-operations trust principal in the healthy state)."
  value       = data.aws_caller_identity.current.account_id
}

output "scenario" {
  description = "Active lab scenario."
  value       = var.scenario
}

output "transit_gateway_id" {
  description = "Transit Gateway (hub) ID -- the Aviatrix-transit stand-in."
  value       = aws_ec2_transit_gateway.hub.id
}

output "spoke_a_instance_id" {
  description = "Spoke A test instance ID (use with SSM Session Manager / Run Command)."
  value       = aws_instance.spoke_a.id
}

output "spoke_b_instance_id" {
  description = "Spoke B test instance ID."
  value       = aws_instance.spoke_b.id
}

output "spoke_a_instance_private_ip" {
  description = "Spoke A test instance private IP (also app.lab.internal)."
  value       = aws_instance.spoke_a.private_ip
}

output "spoke_b_instance_private_ip" {
  description = "Spoke B test instance private IP -- the spoke A -> spoke B ping target."
  value       = aws_instance.spoke_b.private_ip
}

output "network_operations_role_arn" {
  description = "Cross-account-style read-only role ARN. Assume it: aws sts assume-role --role-arn <this> --role-session-name netops"
  value       = aws_iam_role.network_operations.arn
}

output "app_role_arn" {
  description = "Least-privilege app role ARN (contrast with network-operations)."
  value       = aws_iam_role.app.arn
}

output "flow_log_group" {
  description = "CloudWatch Logs group receiving VPC Flow Logs for all three VPCs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "lab_internal_zone_id" {
  description = "Route53 private hosted zone ID for lab.internal."
  value       = aws_route53_zone.lab_internal.zone_id
}

output "next_step" {
  description = "What to do after apply completes."
  value       = local.next_step
}
