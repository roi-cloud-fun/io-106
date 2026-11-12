###############################################################################
# IO-106 AWS Network Architecture -- deploy_box / instances.tf
#
# One SSM-managed deploy box per student_id, named io106-<student_id>-deploy,
# with the lab repo pre-cloned at ~/io-106 and terraform / AWS CLI v2 /
# session-manager-plugin / git / jq installed.
#
# IMPORTANT -- the answer key: the repo's instructor/ directory holds the
# per-scenario fault+fix. It is checked out with git sparse-checkout so
# instructor/ is NEVER materialised on a student box (rather than cloning it and
# deleting it afterwards, which leaves it in .git and in the reflog).
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Account id resolved at plan time so no account number is committed to this
# public repo.
data "aws_caller_identity" "current" {}

locals {
  lab_operator_policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.lab_operator_policy_name}"
}

# --- Instance role -----------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${local.name_prefix}-box"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge(var.tags, { Name = "${local.name_prefix}-box" })
}

# Makes the box a Session Manager target.
resource "aws_iam_role_policy_attachment" "deploy_ssm" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Everything the labs themselves need -- see DEPLOY_BOX_PERMISSIONS.md.
resource "aws_iam_role_policy_attachment" "deploy_lab_operator" {
  role       = aws_iam_role.deploy.name
  policy_arn = local.lab_operator_policy_arn
}

resource "aws_iam_instance_profile" "deploy" {
  name = "${local.name_prefix}-box"
  role = aws_iam_role.deploy.name
}

# --- The deploy boxes --------------------------------------------------------

resource "aws_instance" "deploy" {
  for_each = toset(var.student_ids)

  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.deploy.id]
  iam_instance_profile        = aws_iam_instance_profile.deploy.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  user_data_replace_on_change = true

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee -a /var/log/io106-bootstrap.log) 2>&1

    echo "IO-106 deploy box bootstrap for student ${each.value}"

    dnf -y install git jq unzip dnf-plugins-core

    # Terraform from the official HashiCorp repo (>= 1.10 required by the labs).
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf -y install terraform

    # session-manager-plugin: the labs run `aws ssm start-session` FROM this box
    # to reach the spoke instances, which needs the plugin locally.
    dnf -y install https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm

    # Lab repo at ~/io-106, WITHOUT the instructor/ answer key.
    cd /home/ec2-user
    git clone --no-checkout --branch ${var.repo_branch} ${var.repo_url} io-106
    cd io-106
    git sparse-checkout init --cone
    git sparse-checkout set lab_environment lab_0 lab_1 lab_2 lab_3 lab_4
    git checkout ${var.repo_branch}

    # Land the student in the module directory on login.
    echo 'cd ~/io-106/lab_environment/lab_env_student' >> /home/ec2-user/.bashrc
    echo 'export AWS_DEFAULT_REGION=${var.region}' >> /home/ec2-user/.bashrc
    echo "${each.value}" > /home/ec2-user/.io106-student-id

    chown -R ec2-user:ec2-user /home/ec2-user

    # Bootstrap marker -- `verify_deploy_box.sh` and the instructor checklist
    # look for this before declaring the box ready.
    terraform version   > /home/ec2-user/.io106-bootstrap-complete
    aws --version      >> /home/ec2-user/.io106-bootstrap-complete
    session-manager-plugin --version >> /home/ec2-user/.io106-bootstrap-complete
    jq --version       >> /home/ec2-user/.io106-bootstrap-complete
    chown ec2-user:ec2-user /home/ec2-user/.io106-bootstrap-complete
    echo "BOOTSTRAP OK"
  EOT

  tags = merge(var.tags, {
    Name    = "io106-${each.value}-deploy"
    Student = each.value
  })
}
