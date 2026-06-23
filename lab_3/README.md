# Lab 3: Private Connectivity - Endpoints and DNS

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 2 - Connectivity, Endpoints and DNS |
| **Duration** | 40 minutes |
| **Difficulty** | Advanced |
| **Prerequisites** | Lab 0 deployed and `./verify.sh` all-PASS on the healthy baseline. AWS CLI v2 authenticated to the training account, `session-manager-plugin`, `terraform` >= 1.10, and `jq` pre-installed on your deploy instance. |
| **Builds On** | Lab 0 (your deployed `io106-<student_id>-` stack). This lab reuses the same stack and switches it into the `lab3` fault state. |

---

## Lab Overview

In Lab 0 you deployed a fully private, three-VPC network: a Transit/shared VPC and two spokes, all joined by an AWS Transit Gateway, with no internet gateway and no NAT. The instances reach AWS services through **interface VPC endpoints**, and an application name resolves through a **Route 53 private hosted zone** (`lab.internal`). That private-DNS-over-PrivateLink pattern is exactly how SYF exposes shared AWS services from its central endpoint account.

In this lab you will switch your stack into a fault state where one spoke loses its view of the private DNS zone, diagnose the failure with Systems Manager Session Manager and the Route 53 console, then fix it the way SYF fixes everything — **in Terraform** — and re-verify.

> **Aviatrix disclaimer.** This lab uses AWS Transit Gateway. In your environment the hub-and-spoke transit is **Aviatrix** (Aviatrix Transit Gateway / Spoke Gateways), managed by the network team — the concepts map directly; the management plane differs. The interface endpoints and Route 53 private zone you work with here are AWS-native primitives that ride underneath the Aviatrix overlay either way.

---

## Scenario

A developer reports that an application on **spoke A** can no longer reach a shared service by name: `app.lab.internal` "doesn't resolve." From **spoke B**, the same name resolves fine. The instances are healthy, Session Manager works, and nothing else has changed. Your job is to prove where DNS resolution breaks, identify the exact resource at fault, and restore it through Terraform — not a console click that drifts away from the source of truth.

This mirrors a real SYF failure mode: a VPC silently missing its association to a centrally managed Route 53 private hosted zone. The zone is fine; the *scope* of the zone is wrong.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Explain how a Route 53 private hosted zone is scoped to specific VPCs, and why association is the control that decides who can resolve a private name.
- Reproduce a name-resolution fault by switching the Terraform stack into the `lab3` scenario.
- Diagnose private-DNS failures from inside an instance using SSM Session Manager (`getent`, `dig`, `nslookup`) and confirm the root cause in the Route 53 console.
- Distinguish a DNS *scope* problem from a resolver, routing, or security-group problem.
- Repair the fault in Terraform by restoring the zone-to-VPC association and re-verify with `./verify.sh`.

---

## How the Centralized Endpoint and DNS Model Works

Before you break anything, anchor the healthy design. Three pieces in your stack carry this lab:

1. **Interface VPC endpoints (PrivateLink).** Each spoke has the SSM trio (`ssm`, `ec2messages`, `ssmmessages`) as interface endpoints with private DNS enabled. That is why your instances are manageable over Session Manager with no NAT and no internet gateway. The Transit VPC additionally hosts a **shared STS interface endpoint** — the teachable stand-in for SYF's central endpoint account, where one account owns the endpoints and shares private access to the spokes.

2. **Route 53 private hosted zone `lab.internal`.** It holds an `A` record, `app.lab.internal`, pointing at the spoke A instance's private IP. A private hosted zone only answers queries from VPCs it is **associated** to. Association is the gate.

3. **Transit Gateway.** Carries the cross-VPC traffic once a name resolves to an IP. Routing is healthy in this lab — the fault is purely DNS scope.

In Terraform, the zone and its associations are deliberately separate resources so an association can be dropped without touching the zone:

```hcl
# endpoints.tf - the healthy associations
resource "aws_route53_zone_association" "spoke_a" {
  count = local.is_lab3 ? 0 : 1          # <-- lab3 sets count = 0 (resource removed)

  zone_id = aws_route53_zone.lab_internal.zone_id
  vpc_id  = aws_vpc.this["spoke_a"].id
}

resource "aws_route53_zone_association" "spoke_b" {
  zone_id = aws_route53_zone.lab_internal.zone_id   # always present (control case)
  vpc_id  = aws_vpc.this["spoke_b"].id
}
```
<!-- source: course_outline_v3.md §"Lab 3" -->

That `count = local.is_lab3 ? 0 : 1` is the entire fault. `local.is_lab3` is `true` only when you pass `-var scenario=lab3`, and a Terraform resource with `count = 0` is simply **not created**. Spoke A loses its association; spoke B keeps its. Spoke A's resolver no longer sees the zone, so `app.lab.internal` returns NXDOMAIN.

---

## Task 1: Capture Your Stack Outputs

1. **Reconnect** to your deploy instance (`aws ssm start-session` to `io106-<your_id>-deploy`, the same box as Lab 0) and change into the stack directory:

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    ```

2. **Capture** the outputs you will need into shell variables. These read from local Terraform state — no AWS call — so they work in any state:

    ```bash
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    A_IP=$(terraform output -raw spoke_a_instance_private_ip)
    ZONE_ID=$(terraform output -raw lab_internal_zone_id)
    REGION=$(terraform output -raw region)
    echo "spoke_a=$A_ID  spoke_b=$B_ID  app should be $A_IP  zone=$ZONE_ID"
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

> **Expected Result:** Two instance IDs (`i-...`), the spoke A private IP (a `10.106.1.x` address - this is what `app.lab.internal` should resolve to), and a Route 53 zone ID (`Z...`).

---

## Task 2: Inject the Fault

3. **Apply** the `lab3` scenario. Replace `s01` with your assigned student id (it is also set in `terraform.tfvars`):

    ```bash
    terraform apply -var student_id=s01 -var scenario=lab3
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

    Read the plan before approving. Terraform will report it is **destroying** exactly one resource:

    ```
    # aws_route53_zone_association.spoke_a[0] will be destroyed
    Plan: 0 to add, 0 to change, 1 to destroy.
    ```

4. **Type** `yes` to apply.

> **Expected Result:** Apply completes with `Destroy complete! Resources: 1 destroyed.` The `next_step` output reminds you a fault is active. Only spoke A's zone association is gone - the zone, the record, routing, and security groups are untouched.

> **Teaching note:** This is the IaC version of an operational change. In production, a Terraform plan that says "1 to destroy" on a zone association is the kind of diff a reviewer should catch *before* apply. Reading the plan is a network-engineering control, not a formality.

---

## Task 3: Reproduce the Symptom from Spoke A

5. **Start** a Session Manager shell on the spoke A instance (no SSH, no key pair — this is the only access path in a no-IGW/no-NAT design):

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

6. **Inside the session**, try to resolve the name three ways. `getent` is always present on Amazon Linux 2023; `dig`/`nslookup` come from `bind-utils`:

    ```bash
    getent hosts app.lab.internal; echo "exit=$?"
    sudo dnf install -y bind-utils >/dev/null 2>&1   # if dig/nslookup are missing
    dig +short app.lab.internal
    nslookup app.lab.internal
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** `getent` returns no output and `exit=2` (name not found). `dig +short` prints nothing. `nslookup` reports `** server can't find app.lab.internal: NXDOMAIN`. The name does not resolve from spoke A.

7. **Confirm the instance itself is otherwise healthy** - this rules out a broken resolver or a dead endpoint. From the same session:

    ```bash
    getent hosts ssm.${AWS_REGION:-us-east-1}.amazonaws.com >/dev/null && echo "SSM endpoint resolves — resolver is fine"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

    (Your session exists at all because the SSM interface endpoints and their DNS are working. If the resolver were broken, you would not have a shell here.)

8. **Type** `exit` to leave the session.

---

## Task 4: Prove It Is Scope, Not the Resolver - Test Spoke B

9. **Start** a session on the spoke B instance and resolve the same name:

    ```bash
    aws ssm start-session --target "$B_ID" --region "$REGION"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

    Inside the session:

    ```bash
    getent hosts app.lab.internal
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** Spoke B prints `10.106.1.x  app.lab.internal` — it resolves correctly. Same zone, same record, same Transit Gateway, opposite result. Because spoke B works and spoke A does not, the problem is **not** the zone, the record, or DNS in general. It is that spoke A cannot *see* the zone. That points squarely at the zone-to-VPC association.

10. **Type** `exit` to leave the session.

---

## Task 5: Confirm the Root Cause in Route 53

You can confirm the missing association from the console or the CLI. Use whichever you prefer; both read the same truth.

**Console path:**

11. **Open** the **Route 53** console, go to **Hosted zones**, and click **lab.internal** (it is marked **Private hosted zone**).

12. **Open** the **VPC associations** for the zone (in the hosted-zone detail view, the associated VPCs are listed; choose **Edit** to see the full set).

> **Expected Result:** The zone lists the **Transit** VPC and the **spoke B** VPC as associated, but **not** the spoke A VPC. That missing entry is the fault.

**CLI path (equivalent):**

13. **Run** the following from your terminal:

    ```bash
    aws route53 get-hosted-zone --id "$ZONE_ID" \
      --query 'VPCs[].VPCId' --output text
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** Two VPC IDs are returned. Cross-check them against your VPCs:
>
> ```bash
> aws ec2 describe-vpcs --region "$REGION" \
>   --filters "Name=tag:Name,Values=io106-*-vpc" \
>   --query 'Vpcs[].[Tags[?Key==`Name`].Value|[0],VpcId]' --output text
> ```
>
> The spoke A VPC (`io106-<id>-spoke_a-vpc`) is absent from the zone's VPC list. Diagnosis confirmed: `aws_route53_zone_association.spoke_a` is missing.

---

## Task 6: Fix It in Terraform

You have two ways to restore the association. The **pedagogical fix** edits the source of truth so the repair is permanent and reviewable — that is how SYF operates. (A fast reset alternative is noted at the end.)

14. **Open** `endpoints.tf` in your editor and find the `aws_route53_zone_association.spoke_a` resource. **Delete** the `count` line so the association is created unconditionally, like its spoke B sibling:

    ```hcl
    # BEFORE
    resource "aws_route53_zone_association" "spoke_a" {
      count = local.is_lab3 ? 0 : 1

      zone_id = aws_route53_zone.lab_internal.zone_id
      vpc_id  = aws_vpc.this["spoke_a"].id
    }

    # AFTER  (count guard removed)
    resource "aws_route53_zone_association" "spoke_a" {
      zone_id = aws_route53_zone.lab_internal.zone_id
      vpc_id  = aws_vpc.this["spoke_a"].id
    }
    ```

15. **Apply.** Drop the `-var scenario` flag — with the `count` guard gone, the resource exists regardless of scenario, and omitting the flag returns `scenario` to its healthy default:

    ```bash
    terraform apply -var student_id=s01
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

    Read the plan: Terraform should report it will **add** one resource, the spoke A zone association.

16. **Type** `yes` to apply.

> **Expected Result:** `Apply complete! Resources: 1 added.` Note that removing `count` changes the resource address from `aws_route53_zone_association.spoke_a[0]` back to `aws_route53_zone_association.spoke_a` — Terraform handles this transparently.

---

## Task 7: Re-Verify

17. **Confirm resolution is back** from spoke A:

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    # inside the session:
    getent hosts app.lab.internal
    exit
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** Spoke A now prints `10.106.1.x  app.lab.internal`.

18. **Run the full health check:**

    ```bash
    ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

> **Expected Result:** `ALL CHECKS PASSED -- healthy baseline confirmed.` In particular, check 5 (`app.lab.internal resolves from spoke_a`) now passes. Because you removed the guard rather than just resetting the variable, the fix lives in the Terraform and survives the next apply.

> **Fast reset alternative.** If you only wanted to undo the scenario without editing code, `terraform apply -var student_id=s01 -var scenario=healthy` re-creates the association too. The difference: that path leaves the `count` guard in place, so the fault could be re-injected. Editing the code is the durable fix; resetting the variable is the rehearsal-reset.

---

## Knowledge Checks

**Question 1.** Spoke B resolves `app.lab.internal` but spoke A returns NXDOMAIN, even though both spokes share the same Transit Gateway and the record never changed. Why does association — not routing or the record itself — explain this difference?

<details><summary>Answer</summary>

A Route 53 **private** hosted zone only answers DNS queries that originate in a VPC explicitly **associated** to the zone. The Transit Gateway carries IP traffic *after* a name resolves to an address; it has nothing to do with resolution. The `A` record exists in the zone for every associated VPC. Spoke B is associated, so its VPC resolver sees the zone and answers. Spoke A's association was removed, so spoke A's resolver has no knowledge of `lab.internal` and returns NXDOMAIN. The fault is the *scope* of the zone, not its contents or the network path.
</details>

**Question 2.** During diagnosis you confirmed the spoke A instance could still reach its SSM endpoints and you had a working Session Manager shell. Why does that observation rule out a broken VPC resolver or a security-group problem as the cause?

<details><summary>Answer</summary>

Session Manager only works because the SSM interface endpoints resolve via private DNS and the endpoint security groups permit the instance on 443. If the VPC's `.2` resolver were down, the SSM endpoint names would not resolve and the agent could not connect — you would have no shell. If a security group were blocking, the endpoint connection would fail. The shell working proves the resolver and the endpoint SGs are healthy, which isolates the failure to something specific to the `lab.internal` zone — its association to spoke A.
</details>

**Question 3.** In the Terraform, what does `count = local.is_lab3 ? 0 : 1` do to the `aws_route53_zone_association.spoke_a` resource, and why was the association written as a separate resource from the `aws_route53_zone` itself?

<details><summary>Answer</summary>

`count = local.is_lab3 ? 0 : 1` evaluates to `0` when the scenario is `lab3` (because `local.is_lab3` is `true`), and a resource with `count = 0` is not created — so the spoke A association is absent in the `lab3` state and present otherwise. The association is a separate `aws_route53_zone_association` resource (rather than a `vpc {}` block inside `aws_route53_zone`) precisely so that one VPC's association can be added or removed without recreating or modifying the zone. This is the standard Terraform pattern for centrally owned private zones that many VPCs attach to over time — the kind of model SYF runs from its central endpoint account.
</details>

---

## Lab Summary

You took a healthy private-DNS design, injected a single realistic fault by switching the Terraform stack into `lab3`, and proved the cause methodically: NXDOMAIN from spoke A, clean resolution from spoke B, and a missing VPC in the Route 53 zone's association list. You then fixed it the SYF way — by restoring the `aws_route53_zone_association.spoke_a` resource in Terraform and re-applying — and confirmed the repair with `./verify.sh`.

The transferable lesson: with centralized VPC endpoints and Route 53 private zones, "name doesn't resolve in one VPC but works in another" almost always means a missing or mis-scoped zone association, not a broken resolver. Check association scope first.

**Next:** Lab 4 is the troubleshooting capstone. You will diagnose a *compound* connectivity failure — two independent faults at once — using VPC Flow Logs and Reachability Analyzer from the read-only network-operations role, and fix both in Terraform.

---

## Resources

- [Amazon Route 53 - Working with private hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [Amazon Route 53 - Associating a VPC with a private hosted zone](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-associate-vpcs.html)
- [Amazon VPC - Interface VPC endpoints (AWS PrivateLink)](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html)
- [AWS Systems Manager - Starting a session (Session Manager)](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)
- [Terraform - The `count` meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
