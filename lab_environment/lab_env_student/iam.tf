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

# Trust principal = this account root, in every scenario. The student can always
# ASSUME the network-operations role. The lab2 fault is NOT in the trust policy
# (a trust pointing at a non-existent account is rejected by AWS at apply time):
# it is a PERMISSIONS BOUNDARY that caps the role below its own policy -- see
# netops_boundary below.
locals {
  netops_trust_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
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

# --- lab2 fault: a permissions boundary that caps the role BELOW its policy ----
# The role's own policy (above) grants Reachability Analyzer (network-insights).
# This boundary deliberately OMITS those actions, so the role's EFFECTIVE
# permissions = identity policy AND boundary = read-only describe only. Basic
# describes still work, but `ec2:*NetworkInsights*` (Reachability Analyzer) returns
# AccessDenied even though the role policy allows it -- the classic "I have the
# permission but I'm still denied" puzzle. In SYF's real multi-account org this
# ceiling is usually an SCP at the org/OU level; a single training account cannot
# create SCPs, so we model the identical guardrail with a permissions boundary.
# Fix = remove the boundary (scenario=healthy, or drop the is_lab2 guard).
#
# The boundary POLICY always exists; only its ATTACHMENT to the role is
# conditional (permissions_boundary below). This avoids a teardown race: if the
# policy were count-guarded, toggling lab2 -> healthy would try to DELETE the
# policy while it was still attached -> DeleteConflict. Leaving the (unattached)
# policy in place on healthy is harmless.
data "aws_iam_policy_document" "netops_boundary" {
  statement {
    sid    = "BoundaryMaxReadOnly"
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
}

resource "aws_iam_policy" "netops_boundary" {
  name   = "${local.name_prefix}-netops-boundary"
  policy = data.aws_iam_policy_document.netops_boundary.json
  tags   = { Name = "${local.name_prefix}-netops-boundary" }
}

resource "aws_iam_role" "network_operations" {
  name                 = "${local.name_prefix}-network-operations"
  assume_role_policy   = data.aws_iam_policy_document.netops_trust.json
  max_session_duration = 3600
  permissions_boundary = local.is_lab2 ? aws_iam_policy.netops_boundary.arn : null
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
