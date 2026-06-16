###############################################################################
# IO-106 AWS Network Architecture -- lab_env_student / flowlogs.tf
#
# VPC Flow Logs -> CloudWatch Logs for all three VPCs. This is the primary
# evidence source for Lab 4 (and a useful cross-check in Labs 1 and 3): you
# read ACCEPT/REJECT records to see exactly where a packet was dropped. A
# random suffix on the log group name avoids a name collision if a prior
# destroy left the group behind.
###############################################################################

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/io106/${local.name_prefix}/flowlogs-${random_string.suffix.result}"
  retention_in_days = 1
  tags              = { Name = "${local.name_prefix}-flowlogs" }
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name_prefix}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = { Name = "${local.name_prefix}-flow-logs" }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_permissions.json
}

resource "aws_flow_log" "this" {
  for_each = local.vpcs

  vpc_id          = aws_vpc.this[each.key].id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = { Name = "${local.name_prefix}-${each.key}-flowlog" }
}
