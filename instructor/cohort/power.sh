#!/usr/bin/env bash
###############################################################################
# IO-106 -- park / wake / inspect the per-student deploy boxes.
#
# The boxes bill while running. A 3-day course with evenings and a weekend in
# the middle is a lot of idle t3.small hours, so stop them between sessions.
#
# Stopping an instance does NOT lose anything that matters: the Terraform state
# for each student's lab stack lives on the box's EBS root volume, which
# survives stop/start. Only the private IP can change, and nothing references it.
#
# !! This does NOT stop the NAT gateway !!
#   The NAT bills hourly whether the boxes are up or not (~$0.045/hr). Parking
#   boxes saves the EC2 hours only. To stop paying for NAT you have to
#   `deploy_boxes.sh destroy`, which also destroys the boxes.
#
# !! This does NOT stop the students' lab stacks !!
#   Their spoke instances, TGW and interface endpoints keep billing. Those live
#   in lab_env_student/ state ON each box -- see teardown_all_students.sh.
#
# Usage:
#   ./power.sh status
#   ./power.sh stop
#   ./power.sh start
#   ./power.sh stop user01 user02      # just these students
###############################################################################
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-io106-user}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
REGION="${IO106_REGION:-us-east-2}"

ACTION="${1:-status}"
case "$ACTION" in
  status|stop|start) ;;
  *) echo "usage: $0 {status|stop|start} [student_id ...]" >&2; exit 2 ;;
esac
shift || true

# Component=deploy-box is set by the module's provider default_tags, so this
# filter can never accidentally match a student's spoke instance.
FILTERS=(--filters "Name=tag:Component,Values=deploy-box")
if [ $# -gt 0 ]; then
  FILTERS+=("Name=tag:Student,Values=$(echo "$*" | tr ' ' ',')")
fi

mapfile -t ROWS < <(aws ec2 describe-instances --region "$REGION" "${FILTERS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Student`]|[0].Value,InstanceId,State.Name]' \
  --output text 2>/dev/null | sort)

if [ "${#ROWS[@]}" -eq 0 ] || [ -z "${ROWS[0]:-}" ]; then
  echo "No deploy boxes found in $REGION (tag Component=deploy-box)."
  echo "Have you run ./deploy_boxes.sh apply ?"
  exit 0
fi

printf '%-10s %-22s %s\n' STUDENT INSTANCE STATE
printf '%-10s %-22s %s\n' ------- -------- -----
IDS=()
for r in "${ROWS[@]}"; do
  # shellcheck disable=SC2086
  set -- $r
  printf '%-10s %-22s %s\n' "$1" "$2" "$3"
  case "$ACTION:$3" in
    stop:running)   IDS+=("$2") ;;
    start:stopped)  IDS+=("$2") ;;
  esac
done

[ "$ACTION" = status ] && exit 0

if [ "${#IDS[@]}" -eq 0 ]; then
  echo
  echo "Nothing to $ACTION -- every matching box is already in the target state."
  exit 0
fi

echo
echo "${ACTION}ping ${#IDS[@]} box(es)..."
if [ "$ACTION" = stop ]; then
  aws ec2 stop-instances --region "$REGION" --instance-ids "${IDS[@]}" \
    --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
else
  aws ec2 start-instances --region "$REGION" --instance-ids "${IDS[@]}" \
    --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
  echo
  echo "Give them ~60s to re-register with SSM before handing them to students:"
  echo "  ./power.sh status"
fi
