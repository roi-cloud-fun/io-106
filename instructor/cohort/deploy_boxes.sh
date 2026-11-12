#!/usr/bin/env bash
###############################################################################
# IO-106 -- build (or tear down) the per-student deploy boxes.
#
# Wraps lab_environment/deploy_box/. Pattern borrowed from IO-107's
# instructor/cohort/deploy_workstations.sh, adapted for IO-106:
#
#   - IO-106 boxes are PRIVATE (no public IP) and reached via SSM Session
#     Manager, because that is what CLAUDE.md and every lab guide specify.
#     IO-107 uses the default VPC + EC2 Instance Connect; do not copy that here.
#   - The repo clone on each box EXCLUDES instructor/ (the answer key) via
#     git sparse-checkout. See deploy_box/instances.tf.
#
# LIFECYCLE NOTE (read before swapping the cohort):
#   The instances use for_each keyed by student_id, so each box has an
#   INDEPENDENT lifecycle:
#     - adding an id   -> creates only that box, touches no existing one
#     - removing an id -> destroys only that box
#   The shared pieces (VPC, NAT gateway, security group, IAM role, instance
#   profile) are created once and persist across cohort changes.
#
#   So going from the user50 smoke test to the real class is just:
#     ./deploy_boxes.sh apply user01 user02 user03 user04 user05 \
#                             user06 user07 user08 user09 user10 user50
#   Drop user50 from that list if you want the instructor box gone.
#
# Usage:
#   ./deploy_boxes.sh plan
#   ./deploy_boxes.sh apply                     # uses terraform.tfvars as-is
#   ./deploy_boxes.sh apply user01 user02       # override the student list
#   ./deploy_boxes.sh output
#   ./deploy_boxes.sh destroy                   # end of course
###############################################################################
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${IO106_MODULE_DIR:-$HERE/../deploy_box}"

export AWS_PROFILE="${AWS_PROFILE:-io106-user}"
export AWS_PAGER=""
# Git Bash on Windows rewrites leading-slash arguments into Windows paths,
# which breaks `aws logs` log-group names and SSM document names. Harmless on
# Linux/macOS.
export MSYS_NO_PATHCONV=1

ACTION="${1:-plan}"
case "$ACTION" in
  plan|apply|destroy|output) ;;
  *) echo "usage: $0 {plan|apply|destroy|output} [student_id ...]" >&2; exit 2 ;;
esac
shift || true
STUDENTS="$*"

[ -d "$MODULE" ] || { echo "ERROR: module not found: $MODULE" >&2; exit 1; }

# The state file lives next to the module. If that is inside a Google Drive /
# OneDrive synced folder, a sync client touching terraform.tfstate mid-apply can
# corrupt it -- the same warning lab_environment/README.md gives students.
case "$MODULE" in
  *"My Drive"*|*OneDrive*|*Dropbox*)
    echo "WARNING: module sits on a cloud-synced path:"
    echo "         $MODULE"
    echo "         Pause file sync for the duration of this $ACTION, or set"
    echo "         IO106_MODULE_DIR to a copy on local disk."
    echo
    ;;
esac

TFVARS=()
if [ -n "$STUDENTS" ]; then
  LIST="[\"$(echo "$STUDENTS" | sed 's/  */","/g')\"]"
  TFVARS+=(-var "student_ids=$LIST")
  echo "student_ids override: $LIST"
fi

cd "$MODULE" || exit 1

if [ "$ACTION" = output ]; then
  terraform output
  exit $?
fi

terraform init -input=false -no-color >/dev/null 2>&1 || {
  echo "ERROR: terraform init failed; re-run manually in $MODULE" >&2; exit 1; }

echo "==================== deploy boxes : $ACTION ===================="
APPROVE=()
[ "$ACTION" != plan ] && APPROVE+=(-auto-approve)

terraform "$ACTION" -input=false -no-color "${APPROVE[@]}" "${TFVARS[@]}"
RC=$?

if [ "$ACTION" = apply ] && [ $RC -eq 0 ]; then
  terraform output -json > "$HERE/boxes.json" 2>/dev/null \
    && echo && echo "outputs -> $HERE/boxes.json"
  cat <<'EOT'

Boxes are booting. cloud-init installs terraform / session-manager-plugin / jq
and sparse-clones the repo (~2-3 min), then writes
/home/ec2-user/.io106-bootstrap-complete.

Next:
  ./make_handouts.sh              # per-student connect instructions
  ./prep_all_students.sh          # pre-deploy each student's lab stack
  ./power.sh stop                 # park them until class (they bill running)
EOT
fi

exit $RC
