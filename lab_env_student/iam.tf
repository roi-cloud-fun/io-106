###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / iam.tf
#
# Cross-account access, simulated in a SINGLE account. In [Client]'s real
# environment users sign in via Microsoft Entra ID -> AWS IAM Identity Center
# and assume a scoped role in the TARGET account; the network-operations role
# is a cross-account, read-only "see everything, change nothing" role. Here we
# model that with two roles whose trust policy allows THIS account's callers to
# assume them, so the student can run `aws sts assume-role` and feel the
# pattern without a second account.
###############################################################################

data "aws_caller_identity" "current" {}

# Healthy trust principal = this account root. lab2 swaps it for a bogus
# account so `sts:AssumeRole` returns AccessDenied. Fix = restore the real
# account principal.
locals {
  netops_trust_principal = local.is_lab2 ? "arn:aws:iam::000000000000:root" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

# --- network-operations role (read-only network visibility) -------------------

data "aws_iam_policy_document" "netops_trust" {
  statement {
    sid     = "AllowAccountAssume"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.netops_trust_principal]
    }
  }
}

data "aws_iam_policy_document" "netops_permissions" {
  # Read-only network + IAM visibility.
  statement {
    sid    = "ReadOnlyNetworkVisibility"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetTransitGateway*",
      "ec2:SearchTransitGatewayRoutes",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "route53:Get*",
      "route53:List*",
      "iam:GetRole",
      "iam:ListRoles",
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
  }

  # Reachability Analyzer needs create/describe/delete on network-insights.
  # Not strictly read-only, but required for the Lab 4 diagnostic path.
  statement {
    sid    = "ReachabilityAnalyzer"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInsightsPath",
      "ec2:DeleteNetworkInsightsPath",
      "ec2:CreateNetworkInsightsAnalysis",
      "ec2:DeleteNetworkInsightsAnalysis",
      "ec2:StartNetworkInsightsAnalysis",
      "ec2:DescribeNetworkInsightsPaths",
      "ec2:DescribeNetworkInsightsAnalyses"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "network_operations" {
  name                 = "${local.name_prefix}-network-operations"
  assume_role_policy   = data.aws_iam_policy_document.netops_trust.json
  max_session_duration = 3600
  tags                 = { Name = "${local.name_prefix}-network-operations" }
}

resource "aws_iam_role_policy" "network_operations" {
  name   = "network-visibility"
  role   = aws_iam_role.network_operations.id
  policy = data.aws_iam_policy_document.netops_permissions.json
}

# --- app role (least-privilege contrast) -------------------------------------
# A second, narrower role to contrast with network-operations: it can only
# describe its own instances. Trust is always healthy (this account).

data "aws_iam_policy_document" "app_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "app_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name_prefix}-app"
  assume_role_policy = data.aws_iam_policy_document.app_trust.json
  tags               = { Name = "${local.name_prefix}-app" }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-read"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_permissions.json
}
