###############################################################################
# IO-106 AWS Network Architecture -- deploy_box / variables.tf
###############################################################################

variable "student_ids" {
  description = <<-EOT
    One deploy box per entry. Each becomes an instance named
    io106-<student_id>-deploy. All boxes share one VPC and one NAT gateway, so
    adding students is cheap -- do NOT apply this module once per student or you
    will pay for one NAT gateway each time.
  EOT
  type        = list(string)
  default     = ["user50"]

  validation {
    condition     = length(var.student_ids) > 0 && alltrue([for s in var.student_ids : can(regex("^[a-z0-9]{2,12}$", s))])
    error_message = "Each student_id must be lowercase alphanumeric, 2-12 characters."
  }
}

variable "region" {
  description = "AWS region. Must match the region the students deploy lab_env_student into."
  type        = string
  default     = "us-east-2"
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR for the deploy-box VPC. Must NOT overlap the student stack
    (transit 10.106.0.0/24, spoke A 10.106.1.0/24, spoke B 10.106.2.0/24) -- the
    deploy box reaches the labs through AWS APIs and SSM, never by routing, but
    an overlap would still be confusing to debug.
  EOT
  type        = string
  default     = "10.106.250.0/24"
}

variable "instance_type" {
  description = "Deploy-box instance type. Runs terraform + AWS CLI only; t3.small is comfortable."
  type        = string
  default     = "t3.small"
}

variable "repo_url" {
  description = "The IO-106 lab repo cloned to ~/io-106 on each deploy box."
  type        = string
  default     = "https://github.com/roi-cloud-fun/io-106.git"
}

variable "repo_branch" {
  description = "Branch to check out (the repo's default branch is trunk, not main)."
  type        = string
  default     = "trunk"
}

variable "lab_operator_policy_name" {
  description = <<-EOT
    Customer-managed policy attached to each deploy box's instance role. This is
    lab_environment/deploy_box_iam_policy.json published as a managed policy in
    the training account -- see lab_environment/DEPLOY_BOX_PERMISSIONS.md.
    Without it the box cannot resolve the AL2023 AMI (ssm:GetParameter), create
    the Route 53 private zone, run Reachability Analyzer (tiros:*), or assume the
    lab roles.

    Referenced by NAME, not ARN, so the account id is resolved at plan time from
    the caller's identity and never hardcoded in this repo.
  EOT
  type        = string
  default     = "IO106LabOperator"
}

variable "tags" {
  description = "Extra tags merged into every resource via provider default_tags."
  type        = map(string)
  default     = {}
}
