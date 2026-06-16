# IO-106 Lab Environment — AWS-Native Network, One Stack, Five States

Each of ~8 students deploys their own AWS-native network stack (prefix
`io106-<student_id>-` on every named resource) and uses it to practice transit
routing, cross-account role assumption, private connectivity, and network
troubleshooting. A single `var.scenario` switches the stack between a healthy
baseline and four fault states the student diagnoses and fixes.

> ### Aviatrix disclaimer (read this first — it frames the whole lab)
> **In this lab we use AWS Transit Gateway. In your environment this
> hub-and-spoke transit is provided by Aviatrix (Aviatrix Transit Gateway /
> Spoke Gateways) managed by the network team — the concepts map directly, the
> management plane differs.**
>
> You are building by hand what the Aviatrix Controller automates: the
> encrypted hub-and-spoke transit, the spoke attachments, and the segmentation
> policy. Doing it manually is exactly what makes each failure visible and
> troubleshootable. Where the lab says "Transit Gateway / TGW route table /
> spoke attachment," read "Aviatrix Transit Gateway / segmentation policy /
> Spoke Gateway."

```
                 Transit / shared VPC (10.106.0.0/24)
                 ├─ STS interface endpoint  (central-endpoint-account pattern)
                 └─ Route53 private zone  lab.internal
                            │
                   AWS Transit Gateway (hub)   ← Aviatrix-transit stand-in
                  ┌─────────┴─────────┐
         Spoke A VPC (10.106.1.0/24)   Spoke B VPC (10.106.2.0/24)
         ├─ SSM endpoints (ssm/ec2messages/ssmmessages)   (same in spoke B)
         └─ t3.micro test instance (AL2023, SSM-managed)  (same in spoke B)

   VPC Flow Logs (all 3 VPCs) → CloudWatch Logs
   IAM: network-operations (read-only cross-account-style) + app role
   Security groups ONLY — no NACLs (matches [Client])
```

Fully private: **no IGW, no NAT.** The instances reach Systems Manager and AWS
services through **interface VPC endpoints** — a deliberate cost and teaching
choice (PrivateLink instead of NAT). No SSH, no key pairs; all instance access
is via SSM Session Manager / Run Command.

## Layout

| Path | Who runs it | What |
|------|-------------|------|
| `lab_env_student/` | Each student | The whole network stack (one `terraform apply`) |
| `lab_env_student/verify.sh` | Each student (Lab 0) | PASS/FAIL health verification of the healthy baseline |
| `scenarios/README.md` | Instructor | Answer key: per-scenario symptom → diagnosis → exact fix |

## Prerequisites

- Terraform >= 1.10
- AWS CLI v2 (authenticated to the training account)
- `session-manager-plugin` (for SSM Session Manager / `verify.sh` connectivity tests)
- AWS CloudShell works for all of the above (install Terraform + the SSM plugin).

> Clone to local disk or run in CloudShell — **not** a Google Drive / OneDrive
> synced folder. A cloud-sync client touching `.tfstate` mid-apply can corrupt
> state.

## Student flow

```bash
cd lab_env_student
terraform init
terraform apply -var student_id=s01        # scenario defaults to "healthy"  (~5-8 min)
./verify.sh                                 # Lab 0: PASS/FAIL on every component
```

Then, per the lab guides, switch scenarios to diagnose and fix each fault:

```bash
terraform apply -var student_id=s01 -var scenario=lab1   # spoke A -> spoke B broken
# ...diagnose with Reachability Analyzer + Flow Logs, then fix the Terraform...
terraform apply -var student_id=s01 -var scenario=healthy # reset / confirm fix
```

Notes:

- `student_id` is lowercase alphanumeric, 2-12 chars (s01 … s08). It prefixes
  every named resource so 8 students share one account without collisions.
- Instances take ~2-3 min after apply to register with SSM. If `verify.sh`
  SSM checks FAIL on the first run, wait and re-run.
- The four scenarios and their exact faults/fixes are documented for
  instructors in `scenarios/README.md`. **Lab guides are delivered
  separately** — this directory is the deployable environment only.

## The five states

| `scenario` | State | Concept exercised |
|------------|-------|-------------------|
| `healthy` | Everything works (Lab 0 baseline) | Full topology + verify |
| `lab1` | spoke_a → spoke_b broken (missing VPC route via TGW) | TGW routing + segmentation |
| `lab2` | network-operations role AssumeRole denied (bad trust principal) | Cross-account trust policies |
| `lab3` | spoke_a can't resolve `lab.internal` (zone not associated) | PrivateLink + Route53 private DNS |
| `lab4` | compound: spoke_b SG rule + spoke_b return route missing | Flow Logs + Reachability Analyzer capstone |

Each non-healthy state injects exactly one realistic fault into a real
resource (lab4 is a deliberate two-fault compound). See `scenarios/README.md`.

## Teardown

```bash
cd lab_env_student
terraform destroy -var student_id=s01      # ~5-8 min; nothing blocks here (no NAT/ENI churn)
```

There is no in-cluster machinery to uninstall first (unlike IO-108) — the
stack is pure networking, so a single `destroy` is clean. If `destroy` ever
hangs on a subnet, look for a leftover interface-endpoint ENI in that VPC.

## Cost (us-east-1 list prices, approximate)

Per student, ~8 hr running:

| Item | Rate | ~Day |
|------|------|------|
| AWS Transit Gateway (attachment-hours, 3 attachments) | $0.05/attach/hr | $1.20 |
| 7 × interface VPC endpoints (SSM ×6 + STS ×1) | $0.01/hr each | $0.56 |
| 2 × t3.micro instances | $0.0104/hr each | $0.17 |
| VPC Flow Logs → CloudWatch (lab volume) | trivial | <$0.10 |
| Route53 private hosted zone | $0.50/zone/mo (prorated) | ~$0.02 |
| **Per student** | | **~$2.05/day** |
| **8 students** | | **~$16.40/day** |

The choice to use interface endpoints instead of a NAT gateway trades ~$0.56/day
of endpoints for ~$1.10/day of NAT (and teaches PrivateLink). Destroy stacks at
end of day; rebuild is one `terraform apply`.

> **Not yet deployed live.** This stack is `terraform validate`-clean for all
> scenarios. It has not been applied against a real account at the time of
> writing — first apply should be a smoke test (see "Open items" in the
> handoff notes). The IO-108 sibling stack proved the per-student prefix +
> verify.sh pattern end-to-end.
