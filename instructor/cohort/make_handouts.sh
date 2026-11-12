#!/usr/bin/env bash
###############################################################################
# IO-106 -- per-student connect handouts.
#
# Writes one small markdown file per student under handouts/, containing their
# instance id and the exact start-session command. Paste it into chat / email at
# the top of class so nobody has to hunt for their own box in a shared account.
#
# Students need NOTHING installed locally except AWS CLI v2 + the
# session-manager-plugin to open the session. Everything the labs use
# (terraform, jq, the repo) is already on the box.
#
# Usage:
#   ./make_handouts.sh
#   ./make_handouts.sh user01 user02
###############################################################################
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/handouts"
export AWS_PROFILE="${AWS_PROFILE:-io106-user}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
REGION="${IO106_REGION:-us-east-2}"

mkdir -p "$OUT"

FILTERS=(--filters "Name=tag:Component,Values=deploy-box" "Name=instance-state-name,Values=running,stopped")
if [ $# -gt 0 ]; then
  FILTERS+=("Name=tag:Student,Values=$(echo "$*" | tr ' ' ',')")
fi

mapfile -t ROWS < <(aws ec2 describe-instances --region "$REGION" "${FILTERS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Student`]|[0].Value,InstanceId]' \
  --output text 2>/dev/null | sort)

if [ "${#ROWS[@]}" -eq 0 ] || [ -z "${ROWS[0]:-}" ]; then
  echo "No deploy boxes found in $REGION. Run ./deploy_boxes.sh apply first."
  exit 1
fi

for r in "${ROWS[@]}"; do
  # shellcheck disable=SC2086
  set -- $r
  S="$1"; I="$2"
  F="$OUT/$S.md"

  cat > "$F" <<EOF
# IO-106 — your lab environment ($S)

You do **not** install anything or launch any EC2 instance. A deploy box is
already running for you, with Terraform, the AWS CLI, \`jq\` and the course repo
already on it.

| | |
|---|---|
| **Your student id** | \`$S\` |
| **Your deploy box** | \`io106-$S-deploy\` (\`$I\`) |
| **Region** | \`$REGION\` |

## Connect

Command line:

\`\`\`bash
aws ssm start-session --target $I --region $REGION
\`\`\`

Or in the console: **Systems Manager > Session Manager > Start session**, pick
\`io106-$S-deploy\`, then **Start session**.

There is no SSH, no key pair and no password — access is through Session
Manager, and the box has no public IP.

## When you land

You are dropped straight into the Terraform module the labs use:

\`\`\`bash
cd ~/io-106/lab_environment/lab_env_student   # already your working directory
cat ~/.io106-bootstrap-complete               # tool versions, if you are curious
\`\`\`

Your student id is already set in \`terraform.tfvars\` — every resource you
create is named \`io106-$S-...\`, so you can always find yours in the shared
account.

## If your session drops

SSM sessions time out after about 20 minutes idle. Reconnect with the same
command. Note that **shell variables do not survive a reconnect** — if a lab had
you capture values like \`\$A_ID\` or \`\$B_IP\`, re-run that capture step before
continuing.

## Lab guides

\`~/io-106/lab_0/README.md\` … \`~/io-106/lab_4/README.md\`
EOF

  echo "wrote $F"
done

echo
echo "Handouts in: $OUT"
