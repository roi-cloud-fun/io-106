###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / security_groups.tf
#
# SECURITY GROUPS ONLY -- [Client] does not use NACLs, so neither does this
# lab. SGs are tiered: the endpoint SGs reference the instance SGs BY ID
# (referenced_security_group_id), the stateful SG-to-SG pattern. Cross-VPC
# rules (spoke-to-spoke over the TGW) must use CIDRs -- you cannot reference a
# security group that lives in another VPC.
###############################################################################

# --- Spoke A instance SG -----------------------------------------------------

resource "aws_security_group" "spoke_a_instance" {
  name        = "${local.name_prefix}-spoke-a-instance"
  description = "Spoke A test instance"
  vpc_id      = aws_vpc.this["spoke_a"].id
  tags        = { Name = "${local.name_prefix}-spoke-a-instance" }
}

resource "aws_vpc_security_group_egress_rule" "spoke_a_instance_all" {
  security_group_id = aws_security_group.spoke_a_instance.id
  description       = "All egress (reach SSM endpoints + spoke B over TGW)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow ICMP from spoke B so spoke_a can be pinged from spoke_b (return tests).
resource "aws_vpc_security_group_ingress_rule" "spoke_a_icmp_from_b" {
  security_group_id = aws_security_group.spoke_a_instance.id
  description       = "ICMP from spoke B CIDR"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = var.spoke_b_cidr
}

# --- Spoke B instance SG -----------------------------------------------------

resource "aws_security_group" "spoke_b_instance" {
  name        = "${local.name_prefix}-spoke-b-instance"
  description = "Spoke B test instance"
  vpc_id      = aws_vpc.this["spoke_b"].id
  tags        = { Name = "${local.name_prefix}-spoke-b-instance" }
}

resource "aws_vpc_security_group_egress_rule" "spoke_b_instance_all" {
  security_group_id = aws_security_group.spoke_b_instance.id
  description       = "All egress (reach SSM endpoints + spoke A over TGW)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow ICMP from spoke A so spoke_a -> spoke_b ping works in the healthy
# state. lab4 REMOVES this rule (one of its two compound faults): the packet
# reaches spoke_b's ENI and the SG drops it. Fix = restore this rule.
resource "aws_vpc_security_group_ingress_rule" "spoke_b_icmp_from_a" {
  count = local.is_lab4 ? 0 : 1

  security_group_id = aws_security_group.spoke_b_instance.id
  description       = "ICMP from spoke A CIDR"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = var.spoke_a_cidr
}

# --- Interface-endpoint SGs (one per spoke) ----------------------------------
# Tiered by ID: only the spoke's own instances may reach the endpoint on 443.

resource "aws_security_group" "spoke_a_endpoint" {
  name        = "${local.name_prefix}-spoke-a-endpoint"
  description = "Spoke A interface VPC endpoints (SSM)"
  vpc_id      = aws_vpc.this["spoke_a"].id
  tags        = { Name = "${local.name_prefix}-spoke-a-endpoint" }
}

resource "aws_vpc_security_group_ingress_rule" "spoke_a_endpoint_443" {
  security_group_id            = aws_security_group.spoke_a_endpoint.id
  description                  = "HTTPS from spoke A instances (SG-to-SG by ID)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.spoke_a_instance.id
}

resource "aws_security_group" "spoke_b_endpoint" {
  name        = "${local.name_prefix}-spoke-b-endpoint"
  description = "Spoke B interface VPC endpoints (SSM)"
  vpc_id      = aws_vpc.this["spoke_b"].id
  tags        = { Name = "${local.name_prefix}-spoke-b-endpoint" }
}

resource "aws_vpc_security_group_ingress_rule" "spoke_b_endpoint_443" {
  security_group_id            = aws_security_group.spoke_b_endpoint.id
  description                  = "HTTPS from spoke B instances (SG-to-SG by ID)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.spoke_b_instance.id
}

# --- Shared/centralized endpoint SG (Transit VPC, for the STS endpoint) -------
# Illustrates the central-endpoint-account pattern: it accepts 443 from both
# spoke CIDRs (cross-VPC, so by CIDR) plus the transit VPC itself.

resource "aws_security_group" "transit_endpoint" {
  name        = "${local.name_prefix}-transit-endpoint"
  description = "Transit VPC shared interface endpoint (STS)"
  vpc_id      = aws_vpc.this["transit"].id
  tags        = { Name = "${local.name_prefix}-transit-endpoint" }
}

resource "aws_vpc_security_group_ingress_rule" "transit_endpoint_443_transit" {
  security_group_id = aws_security_group.transit_endpoint.id
  description       = "HTTPS from transit VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.transit_cidr
}

resource "aws_vpc_security_group_ingress_rule" "transit_endpoint_443_spoke_a" {
  security_group_id = aws_security_group.transit_endpoint.id
  description       = "HTTPS from spoke A CIDR (cross-VPC via TGW)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.spoke_a_cidr
}

resource "aws_vpc_security_group_ingress_rule" "transit_endpoint_443_spoke_b" {
  security_group_id = aws_security_group.transit_endpoint.id
  description       = "HTTPS from spoke B CIDR (cross-VPC via TGW)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.spoke_b_cidr
}
