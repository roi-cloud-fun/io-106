###############################################################################
# IO-106 AWS Network Architecture -- deploy_box / outputs.tf
###############################################################################

output "region" {
  description = "Region the deploy boxes live in."
  value       = var.region
}

output "deploy_instance_ids" {
  description = "Map of student_id => deploy-box instance id."
  value       = { for s, i in aws_instance.deploy : s => i.id }
}

output "start_session_commands" {
  description = "Ready-to-paste Session Manager command per student."
  value = {
    for s, i in aws_instance.deploy :
    s => "aws ssm start-session --target ${i.id} --region ${var.region}"
  }
}

output "next_step" {
  description = "What to do once the boxes are up."
  value       = <<-EOT
    Deploy boxes created. Bootstrap (terraform + session-manager-plugin + jq +
    repo clone) runs via user_data and takes ~2-3 minutes after the instance
    reaches "running".

    Confirm a box is ready:
      aws ssm start-session --target <instance-id> --region ${var.region}
      cat ~/.io106-bootstrap-complete     # tool versions == bootstrap finished
      ls ~/io-106                         # lab_environment, lab_0 .. lab_4
      ls ~/io-106/instructor              # MUST NOT EXIST (answer key excluded)

    Then start Lab 0 from ~/io-106/lab_environment/lab_env_student.
  EOT
}
