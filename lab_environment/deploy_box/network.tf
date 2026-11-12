###############################################################################
# IO-106 AWS Network Architecture -- deploy_box / network.tf
#
# A small, boring VPC whose only job is to give the deploy boxes OUTBOUND
# internet so bootstrap can install terraform / session-manager-plugin / jq and
# clone the lab repo from GitHub.
#
# Shape: public subnet (IGW + NAT) / private subnet (the deploy boxes).
# The boxes sit in the PRIVATE subnet with no public IP, per the course's
# "no SSH, no key pair, no public IP" rule -- egress is via the NAT gateway and
# inbound access is via SSM Session Manager only.
#
# Cost note: the NAT gateway is the only non-trivial charge in this module
# (~$0.045/hr + data). One NAT serves every student_id. Destroy this module
# after class.
###############################################################################

locals {
  name_prefix = "io106-deploy"

  public_subnet_cidr  = cidrsubnet(var.vpc_cidr, 2, 0) # 10.106.250.0/26
  private_subnet_cidr = cidrsubnet(var.vpc_cidr, 2, 1) # 10.106.250.64/26
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = local.name_prefix })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-igw" })
}

# --- Public subnet: holds the NAT gateway only -------------------------------

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(var.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, { Name = "${local.name_prefix}-nat" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# --- Private subnet: holds the deploy boxes ----------------------------------

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(var.tags, { Name = "${local.name_prefix}-private" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-private" })
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- Security group: egress only ---------------------------------------------
#
# NO ingress rules at all. Session Manager does not need any: the SSM agent on
# the instance dials OUT to the Systems Manager service, so an inbound-closed
# box is still fully reachable with `aws ssm start-session`.

resource "aws_security_group" "deploy" {
  name        = "${local.name_prefix}-box"
  description = "IO-106 deploy box: egress only, inbound via SSM Session Manager"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-box" })
}

resource "aws_vpc_security_group_egress_rule" "deploy_all" {
  security_group_id = aws_security_group.deploy.id
  description       = "All outbound (package installs, GitHub clone, AWS APIs)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
