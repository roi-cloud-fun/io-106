###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / variables.tf
###############################################################################

variable "student_id" {
  description = "Short student identifier (e.g. s01). Lowercase alphanumeric, 2-12 chars. Prefixes every named resource as io106-<student_id>-."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.student_id))
    error_message = "student_id must be lowercase alphanumeric, 2-12 characters."
  }
}

variable "region" {
  description = "AWS region for the student stack."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = <<-EOT
    Which lab state to deploy. "healthy" is the working baseline (Lab 0).
    Each labN injects exactly one realistic fault into a real resource so the
    student diagnoses and fixes it by editing this Terraform:
      healthy - everything works (Lab 0 baseline)
      lab1    - spoke_a -> spoke_b broken (missing spoke_a VPC route via TGW)
      lab2    - assuming network-operations role fails (bad trust principal)
      lab3    - spoke_a cannot resolve lab.internal (zone not associated to spoke_a)
      lab4    - capstone: spoke_b instance SG rule missing AND spoke_b return route missing
  EOT
  type        = string
  default     = "healthy"

  validation {
    condition     = contains(["healthy", "lab1", "lab2", "lab3", "lab4"], var.scenario)
    error_message = "scenario must be one of: healthy, lab1, lab2, lab3, lab4."
  }
}

variable "transit_cidr" {
  description = "CIDR for the Transit / shared-endpoint VPC (the Aviatrix-transit stand-in)."
  type        = string
  default     = "10.106.0.0/24"
}

variable "spoke_a_cidr" {
  description = "CIDR for spoke VPC A."
  type        = string
  default     = "10.106.1.0/24"
}

variable "spoke_b_cidr" {
  description = "CIDR for spoke VPC B."
  type        = string
  default     = "10.106.2.0/24"
}

variable "instance_type" {
  description = "Instance type for the spoke test instances. Keep tiny -- they only ping/curl."
  type        = string
  default     = "t3.micro"
}

variable "tags" {
  description = "Extra tags merged into every resource via provider default_tags."
  type        = map(string)
  default     = {}
}
