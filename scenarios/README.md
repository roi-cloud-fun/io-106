# IO-106 Lab Scenarios — Instructor Answer Key

This lab uses a single `var.scenario` to switch the stack between a healthy
baseline and four fault states. Each `labN` injects **exactly one realistic
fault into a real resource** (no fake feature flags). The student diagnoses it
with AWS-native tools, then fixes it **by editing the Terraform** and
re-applying.

```bash
# baseline (Lab 0)
terraform apply -var student_id=sNN                       # scenario defaults to healthy

# inject a fault
terraform apply -var student_id=sNN -var scenario=lab1    # ...lab2 / lab3 / lab4

# after the student edits the TF to fix it, OR to reset, return to healthy
terraform apply -var student_id=sNN -var scenario=healthy
```

> **Two ways the student "fixes" it.** The pedagogical path is: the student
> edits the affected resource in the `.tf` file (e.g. removes the `count`
> guard, corrects the principal) and runs `terraform apply` **without** the
> `-var scenario=labN`. Re-applying with `scenario=healthy` is the fast reset.
> The conditionals below show the instructor exactly what each scenario
> toggles.

---

## Aviatrix framing (state this in every lab brief)

> In this lab we use AWS Transit Gateway. In your environment this
> hub-and-spoke transit is provided by Aviatrix (Aviatrix Transit Gateway /
> Spoke Gateways) managed by the network team — the concepts map directly, the
> management plane differs.

So when a lab below says "fix the TGW route table" or "fix the spoke route,"
the real-world equivalent is a segmentation/route policy the Aviatrix
Controller would program — you are doing by hand what the overlay automates,
which is exactly what makes the failure visible and teachable.

---

## Issue → Diagnosis → Fix

| Scenario | Symptom | Diagnostic path (the tool that proves it) | Root cause (real resource) | Fix |
|----------|---------|-------------------------------------------|----------------------------|-----|
| **lab1** — Hub-Spoke Transit & Segmentation | `spoke_a` cannot reach `spoke_b` (ping/curl times out). `spoke_b` → `spoke_a` also fails to complete. | **Reachability Analyzer** path `spoke_a ENI → spoke_b ENI` returns **not reachable**, explanation `no route to destination in the source route table`. Cross-check: **VPC Flow Logs** show spoke_a egress with no matching return; **VPC route table** for spoke_a is missing the `10.106.2.0/24` entry. | `aws_route.spoke_a_to_spoke_b` is removed (its `count` is `0`): spoke_a's VPC route table has no route to spoke_b's CIDR via the TGW, so traffic never reaches the hub. | Restore the spoke_a → spoke_b route via the TGW. (Set scenario back to healthy, or delete the `count = local.is_lab1 ? 0 : 1` guard on `aws_route.spoke_a_to_spoke_b` in `network.tf`.) |
| **lab2** — Cross-Account Access | `aws sts assume-role --role-arn <network_operations_role_arn> --role-session-name netops` fails with **AccessDenied** (not authorized to perform sts:AssumeRole). | **CloudTrail** `AssumeRole` event shows `errorCode: AccessDenied`. Inspect the **role trust policy** (IAM console → Trust relationships, or `aws iam get-role`): the `Principal` is account `000000000000`, not this account. | `local.netops_trust_principal` resolves to `arn:aws:iam::000000000000:root` — the network-operations role trusts a bogus account, so this account's callers cannot assume it. | Correct the trust policy `Principal` back to this account's root (`arn:aws:iam::<ACCOUNT_ID>:root`). (Reset scenario to healthy, or fix the `local.is_lab2` branch in `iam.tf`.) |
| **lab3** — Private Connectivity (Endpoints & DNS) | From `spoke_a`, `app.lab.internal` returns **NXDOMAIN** / does not resolve. From `spoke_b` the same name resolves correctly. | From the spoke_a instance (Session Manager): `getent hosts app.lab.internal` / `dig app.lab.internal` → no answer. **Route53 console** → the `lab.internal` private hosted zone shows it is associated with the transit and spoke_b VPCs but **not** spoke_a. (DNS works inside spoke_a generally — SSM is fine — so it is zone scope, not resolver/SG.) | `aws_route53_zone_association.spoke_a` is removed (its `count` is `0`): the `lab.internal` private hosted zone is not associated to the spoke_a VPC, so spoke_a's Route53 resolver never sees the zone. | Re-associate the `lab.internal` zone to the spoke_a VPC. (Reset scenario to healthy, or remove the `count` guard on `aws_route53_zone_association.spoke_a` in `endpoints.tf`.) |
| **lab4** — Network Troubleshooting (capstone) | `spoke_a` → `spoke_b` fails. This is **compound**: two independent faults must both be found and fixed. | (1) **VPC Flow Logs** for the spoke_b ENI show inbound ICMP from spoke_a with action **REJECT** → a **security group** is blocking it. (2) **Reachability Analyzer** `spoke_b → spoke_a` returns not reachable, `no route to destination` → spoke_b's **VPC route table** is missing `10.106.1.0/24`. Fixing only one leaves it broken — that is the lesson. | Two real resources removed: `aws_vpc_security_group_ingress_rule.spoke_b_icmp_from_a` (spoke_b instance SG no longer allows ICMP from spoke_a) **and** `aws_route.spoke_b_to_spoke_a` (spoke_b's return route to spoke_a via the TGW is gone). | Restore **both**: the spoke_b ingress ICMP rule **and** the spoke_b → spoke_a route. (Reset scenario to healthy, or remove both `count = local.is_lab4 ? 0 : 1` guards — one in `security_groups.tf`, one in `network.tf`.) |

---

## What each scenario toggles (for the instructor)

| Scenario local | File | Resource affected | Healthy | Faulted |
|----------------|------|-------------------|---------|---------|
| `is_lab1` | `network.tf` | `aws_route.spoke_a_to_spoke_b` | present | `count = 0` (removed) |
| `is_lab2` | `iam.tf` | `local.netops_trust_principal` → role trust | this account root | `000000000000` root |
| `is_lab3` | `endpoints.tf` | `aws_route53_zone_association.spoke_a` | present | `count = 0` (removed) |
| `is_lab4` | `security_groups.tf` + `network.tf` | `aws_vpc_security_group_ingress_rule.spoke_b_icmp_from_a` **and** `aws_route.spoke_b_to_spoke_a` | both present | both `count = 0` (removed) |

Only one scenario is ever active at a time (the `var.scenario` validation
enforces a single value), so exactly one fault — or, for lab4, one compound
fault — is present in any given apply.

---

## Reset / cleanup

```bash
terraform apply -var student_id=sNN -var scenario=healthy   # back to a clean baseline
./../lab_env_student/verify.sh                              # confirm all PASS
```

Teardown is a single `terraform destroy` (see `../README.md`).
