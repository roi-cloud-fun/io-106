###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / network.tf
#
# Three VPCs in ONE AZ each (small + cheap): a Transit/shared VPC and two
# spoke VPCs, all attached to an AWS Transit Gateway (the Aviatrix-transit
# stand-in -- see the disclaimer in locals.tf). Every VPC has a /26 workload
# subnet and a /26 TGW-attachment subnet. Fully private: no IGW, no NAT.
# Instances reach AWS services through interface endpoints (endpoints.tf).
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]

  # Per-VPC subnet carve-out from a /24: /26 workload (.0-.63), /26 TGW (.64-.127).
  vpcs = {
    transit = var.transit_cidr
    spoke_a = var.spoke_a_cidr
    spoke_b = var.spoke_b_cidr
  }
}

# --- VPCs --------------------------------------------------------------------

resource "aws_vpc" "this" {
  for_each = local.vpcs

  cidr_block           = each.value
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-${each.key}-vpc" }
}

# --- Subnets -----------------------------------------------------------------

resource "aws_subnet" "workload" {
  for_each = local.vpcs

  vpc_id            = aws_vpc.this[each.key].id
  cidr_block        = cidrsubnet(each.value, 2, 0)
  availability_zone = local.az

  tags = { Name = "${local.name_prefix}-${each.key}-workload" }
}

resource "aws_subnet" "tgw" {
  for_each = local.vpcs

  vpc_id            = aws_vpc.this[each.key].id
  cidr_block        = cidrsubnet(each.value, 2, 1)
  availability_zone = local.az

  tags = { Name = "${local.name_prefix}-${each.key}-tgw" }
}

# --- Transit Gateway (the Aviatrix Transit Gateway stand-in) ------------------

resource "aws_ec2_transit_gateway" "hub" {
  description = "${local.name_prefix} hub -- AWS TGW standing in for Aviatrix Transit Gateway"

  # Default tables disabled so segmentation is explicit and teachable below.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = { Name = "${local.name_prefix}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = local.vpcs

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.this[each.key].id
  subnet_ids         = [aws_subnet.tgw[each.key].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${local.name_prefix}-${each.key}-attach" }
}

# Explicit TGW route table: every attachment is associated AND propagated, so
# in the healthy state all three VPCs can reach each other through the hub.
# (Aviatrix does this segmentation centrally from the Controller.)
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${local.name_prefix}-tgw-rt" }
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  for_each = local.vpcs

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = local.vpcs

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# --- VPC route tables --------------------------------------------------------
# One private route table per VPC, shared by its workload + tgw subnets.
# Cross-VPC destinations point at the TGW. The "broken" routes for lab1/lab4
# are defined separately below via count so the fault is a single real route.

resource "aws_route_table" "this" {
  for_each = local.vpcs

  vpc_id = aws_vpc.this[each.key].id
  tags   = { Name = "${local.name_prefix}-${each.key}-rt" }
}

resource "aws_route_table_association" "workload" {
  for_each = local.vpcs

  subnet_id      = aws_subnet.workload[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

resource "aws_route_table_association" "tgw" {
  for_each = local.vpcs

  subnet_id      = aws_subnet.tgw[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

# Transit VPC reaches both spokes via the TGW (always healthy).
resource "aws_route" "transit_to_spoke_a" {
  route_table_id         = aws_route_table.this["transit"].id
  destination_cidr_block = var.spoke_a_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "transit_to_spoke_b" {
  route_table_id         = aws_route_table.this["transit"].id
  destination_cidr_block = var.spoke_b_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Spoke A -> Transit (always healthy: needed to reach shared STS endpoint).
resource "aws_route" "spoke_a_to_transit" {
  route_table_id         = aws_route_table.this["spoke_a"].id
  destination_cidr_block = var.transit_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Spoke B -> Transit (always healthy).
resource "aws_route" "spoke_b_to_transit" {
  route_table_id         = aws_route_table.this["spoke_b"].id
  destination_cidr_block = var.transit_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Spoke A -> Spoke B. lab1 REMOVES this route: spoke_a loses its path to
# spoke_b's CIDR, so traffic never reaches the TGW. Fix = restore this route.
resource "aws_route" "spoke_a_to_spoke_b" {
  count = local.is_lab1 ? 0 : 1

  route_table_id         = aws_route_table.this["spoke_a"].id
  destination_cidr_block = var.spoke_b_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Spoke B -> Spoke A (the return path). lab4 REMOVES this route as one of its
# two compound faults. Fix = restore this route.
resource "aws_route" "spoke_b_to_spoke_a" {
  count = local.is_lab4 ? 0 : 1

  route_table_id         = aws_route_table.this["spoke_b"].id
  destination_cidr_block = var.spoke_a_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
