###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / endpoints.tf
#
# Private connectivity without NAT or an IGW:
#   - SSM trio (ssm + ec2messages + ssmmessages) interface endpoints in EACH
#     spoke VPC, private DNS enabled. This is what keeps the instances online
#     in Systems Manager with no NAT gateway -- a deliberate cost + teaching
#     choice (PrivateLink instead of NAT). In [Client]'s real environment
#     these endpoints are CENTRALIZED in a dedicated endpoint account and
#     shared; here we keep them per-spoke so both instances stay manageable
#     while the shared-endpoint pattern is shown by the STS endpoint below.
#   - A shared STS interface endpoint in the Transit VPC -- the teachable
#     "central endpoint account" example.
#   - A Route53 private hosted zone (lab.internal) associated to the spokes,
#     with an A record pointing at the spoke A instance. This is the DNS
#     teaching + Lab 3 fault surface.
###############################################################################

# --- SSM trio per spoke ------------------------------------------------------

resource "aws_vpc_endpoint" "spoke_a_ssm" {
  for_each = toset(local.ssm_services)

  vpc_id              = aws_vpc.this["spoke_a"].id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.workload["spoke_a"].id]
  security_group_ids  = [aws_security_group.spoke_a_endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-spoke-a-${each.value}" }
}

resource "aws_vpc_endpoint" "spoke_b_ssm" {
  for_each = toset(local.ssm_services)

  vpc_id              = aws_vpc.this["spoke_b"].id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.workload["spoke_b"].id]
  security_group_ids  = [aws_security_group.spoke_b_endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-spoke-b-${each.value}" }
}

# --- Shared STS endpoint in the Transit VPC (central-endpoint pattern) --------

resource "aws_vpc_endpoint" "transit_sts" {
  vpc_id              = aws_vpc.this["transit"].id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.workload["transit"].id]
  security_group_ids  = [aws_security_group.transit_endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-transit-sts" }
}

# --- Route53 private hosted zone (lab.internal) ------------------------------
# Created associated to the Transit VPC; spoke associations are separate
# resources so lab3 can drop spoke A's without touching the zone itself.

resource "aws_route53_zone" "lab_internal" {
  name    = "lab.internal"
  comment = "${local.name_prefix} private zone"

  vpc {
    vpc_id = aws_vpc.this["transit"].id
  }

  # Spoke associations are managed by aws_route53_zone_association below;
  # ignore drift on the vpc set so the two do not fight.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = { Name = "${local.name_prefix}-lab-internal" }
}

# Spoke A association. lab3 REMOVES this: spoke A can no longer resolve
# app.lab.internal (NXDOMAIN) while spoke B still resolves it. Fix = restore
# this association.
resource "aws_route53_zone_association" "spoke_a" {
  count = local.is_lab3 ? 0 : 1

  zone_id = aws_route53_zone.lab_internal.zone_id
  vpc_id  = aws_vpc.this["spoke_a"].id
}

# Spoke B association (always healthy -- the working control case for lab3).
resource "aws_route53_zone_association" "spoke_b" {
  zone_id = aws_route53_zone.lab_internal.zone_id
  vpc_id  = aws_vpc.this["spoke_b"].id
}

# An A record pointing at something in-VPC: the spoke A test instance.
resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.lab_internal.zone_id
  name    = "app.lab.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.spoke_a.private_ip]
}
