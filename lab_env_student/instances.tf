###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / instances.tf
#
# One tiny SSM-managed test instance per spoke. These are the connectivity
# probes: you ping/curl between them and to AWS services using SSM Run Command
# / Session Manager. NO SSH, NO key pair, NO public IP -- all access is via
# Systems Manager over the interface endpoints. Amazon Linux 2023 ships the
# SSM agent preinstalled, so once the endpoints + endpoint SG are healthy the
# instances register automatically.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- Instance profile for SSM ------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name_prefix}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-instance" }
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name_prefix}-instance"
  role = aws_iam_role.instance.name
}

# --- Spoke A instance --------------------------------------------------------

resource "aws_instance" "spoke_a" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.workload["spoke_a"].id
  vpc_security_group_ids      = [aws_security_group.spoke_a_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = { Name = "${local.name_prefix}-spoke-a" }
}

# --- Spoke B instance --------------------------------------------------------

resource "aws_instance" "spoke_b" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.workload["spoke_b"].id
  vpc_security_group_ids      = [aws_security_group.spoke_b_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = { Name = "${local.name_prefix}-spoke-b" }
}
