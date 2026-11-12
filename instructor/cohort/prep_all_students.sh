#!/usr/bin/env bash
###############################################################################
# IO-106 -- pre-deploy each student's lab stack ON their own deploy box.
#
# WHY ON THE BOX, and not from here:
#   Labs 1-4 are `terraform apply -var scenario=labN` plus editing the count
#   guards, so each student must own WRITABLE state for their own stack.
#   IO-106 uses local state on the deploy box (DEPLOY_BOX_PERMISSIONS.md:30 --
#   "Assumes local Terraform state on the deploy box, no S3/DynamoDB backend").
#
#   If you applied all 11 stacks from one machine instead, the state would live
#   in ONE file here and students could not run Labs 1-4 at all. And they cannot
#   get it via `git clone` either -- the repo's .gitignore excludes *.tfstate
#   and terraform.tfvars by design.
#
#   Running the apply over SSM on each box puts terraform.tfstate exactly where
#   Labs 1-4 expect it: ~/io-106/lab_environment/lab_env_student/.
#
# This is also the per-student rescue path. If you let students run Lab 0
# themselves and one of them fails, prep just that student:
#   ./prep_all_students.sh user07
#
# QUOTAS -- read before running for a full cohort:
#   Each stack is 3 VPCs + 1 transit gateway + 7 interface endpoints + 2
#   instances. 11 students is ~35 VPCs and 11 TGWs against AWS defaults of 5
#   and 5. Raise those limits first or most of these applies will fail.
#
# Usage:
#   ./prep_all_students.sh                 # every box found
#   ./prep_all_students.sh user01 user02   # just these
###############################################################################
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-io106-user}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
export PYTHONIOENCODING=utf-8     # terraform output contains box-drawing chars
REGION="${IO106_REGION:-us-east-2}"
SCENARIO="${IO106_SCENARIO:-healthy}"

FILTERS=(--filters "Name=tag:Component,Values=deploy-box" "Name=instance-state-name,Values=running")
if [ $# -gt 0 ]; then
  FILTERS+=("Name=tag:Student,Values=$(echo "$*" | tr ' ' ',')")
fi

mapfile -t ROWS < <(aws ec2 describe-instances --region "$REGION" "${FILTERS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Student`]|[0].Value,InstanceId]' \
  --output text 2>/dev/null | sort)

if [ "${#ROWS[@]}" -eq 0 ] || [ -z "${ROWS[0]:-}" ]; then
  echo "No RUNNING deploy boxes found in $REGION."
  echo "  ./power.sh status    # are they stopped?"
  echo "  ./deploy_boxes.sh apply"
  exit 1
fi

echo "Will deploy scenario=$SCENARIO for ${#ROWS[@]} student(s) in $REGION:"
printf '  %s\n' "${ROWS[@]}"
echo
echo "Each apply is ~6 minutes of AWS time and they run concurrently."
echo

declare -A CMD STUDENT_OF
for r in "${ROWS[@]}"; do
  # shellcheck disable=SC2086
  set -- $r
  S="$1"; I="$2"

  # Base64 the payload so no shell quoting survives to fight us through the
  # SSM parameters JSON.
  PAYLOAD=$(base64 -w0 <<REMOTE
#!/bin/bash
set -euo pipefail
cd /home/ec2-user/io-106/lab_environment/lab_env_student
cat > terraform.tfvars <<'TFV'
student_id = "$S"
region     = "$REGION"
scenario   = "$SCENARIO"
TFV
terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color
echo "----- verify.sh -----"
bash ./verify.sh
REMOTE
)

  C=$(aws ssm send-command --region "$REGION" --instance-ids "$I" \
        --document-name AWS-RunShellScript --timeout-seconds 3600 \
        --comment "IO-106 prep $S" \
        --parameters commands="[\"echo $PAYLOAD | base64 -d > /tmp/io106_prep.sh\",\"chmod 0755 /tmp/io106_prep.sh\",\"chown ec2-user:ec2-user /tmp/io106_prep.sh\",\"su - ec2-user -c 'bash /tmp/io106_prep.sh'\"]" \
        --query 'Command.CommandId' --output text 2>/dev/null)

  if [ -z "$C" ] || [ "$C" = "None" ]; then
    echo "  $S: FAILED to dispatch (is the SSM agent online?)"
    continue
  fi
  CMD[$S]="$C"; STUDENT_OF[$C]="$S"
  echo "  $S -> dispatched ($C)"
done

echo
echo "Waiting for applies to finish..."
PENDING=1
while [ "$PENDING" -gt 0 ]; do
  sleep 30
  PENDING=0
  for S in "${!CMD[@]}"; do
    ST=$(aws ssm list-command-invocations --region "$REGION" --command-id "${CMD[$S]}" \
           --query 'CommandInvocations[0].Status' --output text 2>/dev/null)
    case "$ST" in
      Success|Failed|Cancelled|TimedOut) ;;
      *) PENDING=$((PENDING+1)) ;;
    esac
  done
  echo "  still running: $PENDING"
done

echo
echo "================================ RESULTS ================================"
FAIL=0
for S in $(echo "${!CMD[@]}" | tr ' ' '\n' | sort); do
  OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "${CMD[$S]}" \
          --instance-id "$(aws ec2 describe-instances --region "$REGION" \
             --filters "Name=tag:Student,Values=$S" "Name=tag:Component,Values=deploy-box" \
             --query 'Reservations[0].Instances[0].InstanceId' --output text)" \
          --query 'StandardOutputContent' --output text 2>/dev/null)

  if echo "$OUT" | grep -q "ALL CHECKS PASSED"; then
    printf '  %-10s PASS  (%s)\n' "$S" "$(echo "$OUT" | grep -o 'Apply complete.*' | head -1)"
  else
    printf '  %-10s FAIL  -- investigate:\n' "$S"
    echo "$OUT" | grep -iE "Error|FAIL:" | head -5 | sed 's/^/             /'
    FAIL=$((FAIL+1))
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All students ready. Hand out connect instructions:  ./make_handouts.sh"
else
  echo "$FAIL student(s) need attention. Re-run for just those, e.g.:"
  echo "  ./prep_all_students.sh userNN"
fi
exit "$FAIL"
