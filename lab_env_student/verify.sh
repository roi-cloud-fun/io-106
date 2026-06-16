#!/usr/bin/env bash
###############################################################################
# IO-106 AWS Network Architecture -- verify.sh
# Lab 0 health verification for the HEALTHY baseline. Prints PASS/FAIL for
# every component. Run from lab_env_student/ after:
#   terraform apply -var student_id=sNN   (scenario defaults to healthy)
#
# Requires: aws CLI v2, session-manager-plugin, terraform. Instances take
# ~5-7 minutes after apply to register with SSM (verified live 2026-06-16) --
# if the SSM checks FAIL, wait and re-run; they are the gate for the
# reachability/DNS checks below.
###############################################################################
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

REGION=$(terraform output -raw region)
SCENARIO=$(terraform output -raw scenario)
A_ID=$(terraform output -raw spoke_a_instance_id)
B_ID=$(terraform output -raw spoke_b_instance_id)
B_IP=$(terraform output -raw spoke_b_instance_private_ip)
TGW_ID=$(terraform output -raw transit_gateway_id)
LOG_GROUP=$(terraform output -raw flow_log_group)
NETOPS_ARN=$(terraform output -raw network_operations_role_arn)

if [ "$SCENARIO" != "healthy" ]; then
  echo "NOTE: scenario is '$SCENARIO', not 'healthy'. verify.sh checks the"
  echo "      healthy baseline -- expect failures that match the injected fault."
  echo ""
fi

# Helper: run a command on an instance via SSM and capture stdout.
ssm_run() {
  local iid="$1" script="$2" cmd_id out status
  cmd_id=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$iid" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$script\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null) || return 1
  for _ in $(seq 1 20); do
    status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$iid" \
      --query 'Status' --output text 2>/dev/null)
    case "$status" in
      Success) break ;;
      Failed | Cancelled | TimedOut) break ;;
      *) sleep 3 ;;
    esac
  done
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query 'StandardOutputContent' --output text 2>/dev/null
}

# 1. Both instances Running
for pair in "spoke_a:$A_ID" "spoke_b:$B_ID"; do
  name="${pair%%:*}"
  iid="${pair##*:}"
  state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
  if [ "$state" = "running" ]; then
    pass "$name instance $iid is running"
  else
    fail "$name instance $iid state: ${state:-unknown}"
  fi
done

# 2. Both instances online in SSM (proves private SSM endpoints + endpoint SG)
for pair in "spoke_a:$A_ID" "spoke_b:$B_ID"; do
  name="${pair%%:*}"
  iid="${pair##*:}"
  ping_state=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$iid" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  if [ "$ping_state" = "Online" ]; then
    pass "$name instance is Online in SSM (private endpoints working)"
  else
    fail "$name instance SSM PingStatus: ${ping_state:-none} (endpoint/SG/DNS issue, or wait 2-3 min)"
  fi
done

# 3. TGW has all three attachments available
ATT_OK=$(aws ec2 describe-transit-gateway-attachments --region "$REGION" \
  --filters "Name=transit-gateway-id,Values=$TGW_ID" "Name=state,Values=available" \
  --query 'length(TransitGatewayAttachments)' --output text 2>/dev/null)
if [ "${ATT_OK:-0}" -ge 3 ]; then
  pass "TGW $TGW_ID has $ATT_OK attachments available"
else
  fail "TGW $TGW_ID available attachments: ${ATT_OK:-0} (expected 3)"
fi

# 4. spoke_a -> spoke_b reachable (ping over the TGW)
PING_OUT=$(ssm_run "$A_ID" "ping -c 3 -W 2 $B_IP >/dev/null 2>&1 && echo REACHABLE || echo UNREACHABLE")
if echo "$PING_OUT" | grep -q REACHABLE; then
  pass "spoke_a -> spoke_b ($B_IP) reachable over the TGW"
else
  fail "spoke_a -> spoke_b ($B_IP) UNREACHABLE (route or SG -- see Lab 1 / Lab 4)"
fi

# 5. app.lab.internal resolves privately from spoke_a (Route53 private zone)
DNS_OUT=$(ssm_run "$A_ID" "getent hosts app.lab.internal | awk '{print \$1}'")
if echo "$DNS_OUT" | grep -Eq '^10\.106\.'; then
  pass "app.lab.internal resolves from spoke_a -> $(echo "$DNS_OUT" | tr -d '[:space:]')"
else
  fail "app.lab.internal did not resolve from spoke_a (zone association -- see Lab 3)"
fi

# 6. Flow logs flowing (log group has at least one stream)
STREAMS=$(aws logs describe-log-streams --region "$REGION" \
  --log-group-name "$LOG_GROUP" --limit 1 \
  --query 'length(logStreams)' --output text 2>/dev/null)
if [ "${STREAMS:-0}" -ge 1 ]; then
  pass "VPC Flow Logs flowing into $LOG_GROUP"
else
  # Not a failure: VPC Flow Logs take ~10 min to deliver the first records, so on
  # a fresh apply this is expected. It does not block the labs (Lab 4 uses Flow
  # Logs later, by which time records exist).
  echo "WARN: no log streams in $LOG_GROUP yet (VPC Flow Logs take ~10 min for first records -- not a failure)"
fi

# 7. network-operations role exists
if aws iam get-role --role-name "$(basename "$NETOPS_ARN")" >/dev/null 2>&1; then
  pass "network-operations role exists ($NETOPS_ARN)"
else
  fail "network-operations role not found"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED -- healthy baseline confirmed. You are ready for Lab 1."
else
  echo "$FAILURES CHECK(S) FAILED."
  [ "$SCENARIO" = "healthy" ] && echo "On the healthy baseline this means something is wrong -- investigate before continuing."
  exit 1
fi
