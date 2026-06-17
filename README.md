# IO-106 — AWS Network Architecture and Cross-Account Access

Monorepo for ROI Training's IO-106 course. **Contains everything you need to stand up and run the labs end-to-end:** the per-student Terraform environment, the step-by-step lab guides, and the instructor answer key.

Each of ~8 students deploys their own AWS-native network stack (prefix `io106-<student_id>-` on every named resource) and uses it to practice transit routing, cross-account role assumption, permission guardrails, private connectivity, and network troubleshooting. A single `var.scenario` switches the stack between a healthy baseline and four fault states the student diagnoses and fixes.

## What's where

```
io-106/
├── instructor/
│   └── scenarios.md                  Answer key: per-scenario symptom → diagnosis → exact fix.
│                                      Do NOT ship this to students — exclude it from the deploy-box clone.
├── lab_environment/
│   └── lab_env_student/              The whole network stack — one `terraform apply` provisions it.
│       ├── network.tf  iam.tf  endpoints.tf  security_groups.tf  flowlogs.tf  instances.tf …
│       ├── variables.tf              student_id, region, scenario
│       ├── verify.sh                 Lab 0 PASS/FAIL health check
│       └── terraform.tfvars.example  Copy to terraform.tfvars and fill in
│
├── lab_0/README.md   Deploy Your Network Stack (baseline + verify)
├── lab_1/README.md   Hub-Spoke Transit and Segmentation (TGW routing fault)
├── lab_2/README.md   Cross-Account Access and Permission Guardrails (permissions-boundary fault)
├── lab_3/README.md   Private Connectivity — Endpoints and DNS (Route53 zone-association fault)
└── lab_4/README.md   Network Troubleshooting capstone (compound SG + route fault)
```

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
   Security groups ONLY — no NACLs (matches SYF)
```

Fully private: **no IGW, no NAT.** The instances reach Systems Manager and AWS services through **interface VPC endpoints** — a deliberate cost and teaching choice (PrivateLink instead of NAT). No SSH, no key pairs; all instance access is via SSM Session Manager / Run Command.

## How students run it

Students work from a per-student **EC2 deploy instance** (`io106-<student_id>-deploy`), reached over SSM Session Manager — no laptops, no CloudShell. This repo is pre-cloned on that box at `~/io-106`, with Terraform, AWS CLI v2, `session-manager-plugin`, `git`, and `jq` preinstalled. The per-lab guides (`lab_0/`…`lab_4/`) walk through everything; the short version:

```bash
cd ~/io-106/lab_environment/lab_env_student
terraform init
terraform apply -var student_id=s01        # scenario defaults to "healthy"  (~5-8 min)
./verify.sh                                 # Lab 0: PASS/FAIL on every component
```

Then, per the lab guides, switch scenarios to diagnose and fix each fault:

```bash
terraform apply -var student_id=s01 -var scenario=lab1   # spoke A -> spoke B broken
# ...diagnose, then fix the Terraform...
terraform apply -var student_id=s01 -var scenario=healthy # reset / confirm fix
```

Notes:

- `student_id` is lowercase alphanumeric, 2-12 chars (s01 … s08). It prefixes every named resource so 8 students share one account without collisions.
- Instances take ~2-3 min after apply to register with SSM. If `verify.sh` SSM checks FAIL on the first run, wait and re-run.
- The four scenarios and their exact faults/fixes are documented for instructors in `instructor/scenarios.md`.

## The five states

| `scenario` | State | Concept exercised |
|------------|-------|-------------------|
| `healthy` | Everything works (Lab 0 baseline) | Full topology + verify |
| `lab1` | spoke_a → spoke_b broken (missing VPC route via TGW) | TGW routing + segmentation |
| `lab2` | network-operations role can be assumed and `describe` works, but Reachability Analyzer is denied | Permission guardrails: a **permissions boundary** caps the role below its policy (single-account stand-in for an **SCP**) |
| `lab3` | spoke_a can't resolve `lab.internal` (zone not associated) | PrivateLink + Route53 private DNS |
| `lab4` | compound: spoke_b SG rule + spoke_b return route missing | Flow Logs + Reachability Analyzer capstone |

Each non-healthy state injects exactly one realistic fault into a real resource (lab4 is a deliberate two-fault compound). See `instructor/scenarios.md`.

## Teardown

```bash
cd ~/io-106/lab_environment/lab_env_student
terraform destroy -var student_id=s01      # ~5-8 min; nothing blocks here (no NAT/ENI churn)
```

There is no in-cluster machinery to uninstall first (unlike IO-108) — the stack is pure networking, so a single `destroy` is clean. If `destroy` ever hangs on a subnet, look for a leftover interface-endpoint ENI in that VPC.

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

(A per-student EC2 deploy box adds one more small instance per student.) Destroy stacks at end of day; rebuild is one `terraform apply`.

## Status

**Deployed and live-tested 2026-06-17** against a real training account (76 resources, clean apply + destroy). All five scenarios were exercised end-to-end:

- `healthy`, `lab1`, `lab3`, `lab4` — verified (lab4 connectivity fault confirmed via raw ICMP loss).
- `lab2` — rebuilt as the permissions-boundary fault (the original "wrong-account trust" fault is rejected by AWS at apply time) and verified: healthy = Reachability Analyzer allowed, lab2 = denied, toggle clean both ways.
- `verify.sh` reachability check fixed (it previously reported a false "reachable").
