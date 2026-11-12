# Lab 3: Private Connectivity - Endpoints and DNS

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 2 - Connectivity, Endpoints and DNS |
| **Duration** | 40 minutes, plus an optional 10-minute bonus task (Task 8) |
| **Difficulty** | Advanced |
| **Prerequisites** | Lab 0 deployed and `./verify.sh` all-PASS on the healthy baseline. AWS CLI v2 authenticated to the training account, `session-manager-plugin`, `terraform` >= 1.10, and `jq` pre-installed on your deploy instance. |
| **Builds On** | Lab 0 (your deployed `io106-<student_id>-` stack). This lab reuses the same stack and switches it into the `lab3` fault state. |

---

## Lab Overview

In Lab 0 you deployed a fully private, three-VPC network: a Transit/shared VPC and two spokes, all joined by an AWS Transit Gateway, with no internet gateway and no NAT. The instances reach AWS services through **interface VPC endpoints**, and an application name resolves through a **Route 53 private hosted zone** (`lab.internal`). That private-DNS-over-PrivateLink pattern is exactly how SYF exposes shared AWS services from its central endpoint account.

In this lab you will switch your stack into a fault state where one spoke loses its view of the private DNS zone, diagnose the failure with Systems Manager Session Manager and the Route 53 console, then fix it the way SYF fixes everything - **in Terraform** - and re-verify.

> **Aviatrix disclaimer.** This lab uses AWS Transit Gateway. In your environment the hub-and-spoke transit is **Aviatrix** (Aviatrix Transit Gateway / Spoke Gateways), managed by the network team - the concepts map directly; the management plane differs. The interface endpoints and Route 53 private zone you work with here are AWS-native primitives that ride underneath the Aviatrix overlay either way.

---

## Scenario

A developer reports that an application on **spoke A** can no longer reach a shared service by name: `app.lab.internal` "doesn't resolve." From **spoke B**, the same name resolves fine. The instances are healthy, Session Manager works, and nothing else has changed. Your job is to prove where DNS resolution breaks, identify the exact resource at fault, and restore it through Terraform - not a console click that drifts away from the source of truth.

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

1. **Interface VPC endpoints (PrivateLink).** Each spoke has the SSM trio (`ssm`, `ec2messages`, `ssmmessages`) as interface endpoints with private DNS enabled. That is why your instances are manageable over Session Manager with no NAT and no internet gateway. The Transit VPC additionally hosts a **shared STS interface endpoint** - the teachable stand-in for SYF's central endpoint account, where one account owns the endpoints and shares private access to the spokes.

    Note one thing now, because it is the subject of the bonus task at the end of this lab: **"private DNS enabled" is scoped to the endpoint's own VPC.** Enabling it creates a hidden, AWS-managed private hosted zone containing a record for the service's public name that resolves to "the private IP addresses of the endpoint network interfaces **in your VPC**" ([AWS PrivateLink docs](https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html)). You cannot associate that hidden zone with another VPC. So the shared STS endpoint in the Transit VPC is *reachable* from the spokes over the Transit Gateway, but the name `sts.<region>.amazonaws.com` does **not** resolve to it from spoke A. DNS scope, again - the same lesson as the fault you are about to inject, one layer down.

2. **Route 53 private hosted zone `lab.internal`.** It holds an `A` record, `app.lab.internal`, pointing at the spoke A instance's private IP. A private hosted zone only answers queries from VPCs it is **associated** to. Association is the gate.

3. **Transit Gateway.** Carries the cross-VPC traffic once a name resolves to an IP. Routing is healthy in this lab - the fault is purely DNS scope.

In Terraform, the zone and its associations are deliberately **separate resources**, so an association can be dropped without touching the zone. In `endpoints.tf`, spoke A's association (`aws_route53_zone_association.spoke_a`) carries a `count = local.is_lab3 ? 0 : 1` guard, while spoke B's is unconditional (the control case). That `count` guard is the entire fault: `local.is_lab3` is `true` only when you pass `-var scenario=lab3`, and a Terraform resource with `count = 0` is simply **not created**. Spoke A loses its association; spoke B keeps its, so spoke A's resolver no longer sees the zone and `app.lab.internal` returns NXDOMAIN. You will see and edit this exact resource in Task 6.

---

## Task 1: Capture Your Stack Outputs

1. **Reconnect** to your deploy instance (`aws ssm start-session` to `io106-<your_id>-deploy`, the same box as Lab 0) and change into the stack directory:

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    ```

2. **Capture** the outputs you will need into shell variables. These read from local Terraform state - no AWS call - so they work in any state:

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

3. **Apply** the `lab3` scenario. Your `student_id` is already set in `terraform.tfvars` - do **not** pass `-var student_id` on the command line: a hardcoded id renames every resource and makes Terraform try to destroy and recreate your whole stack.

    ```bash
    terraform plan -var scenario=lab3     # ALWAYS read the plan first - this is the control the teaching note describes
    terraform apply -var scenario=lab3
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

    Read the plan before approving. Terraform will report it is **destroying** exactly one resource:

    ```
    # aws_route53_zone_association.spoke_a[0] will be destroyed
    Plan: 0 to add, 0 to change, 1 to destroy.
    ```

4. **Type** `yes` to apply.

> **Expected Result:** Apply completes with `Destroy complete! Resources: 1 destroyed.` The `next_step` output reminds you a fault is active. Only spoke A's zone association is gone - the zone, the record, routing, and security groups are untouched.

> **This one apply is slow - that is normal.** Route 53 zone-association changes
> take a while: removing the association was measured at **1m46s** on this stack,
> and Terraform prints `Still destroying...` every 10 seconds while it waits. One
> resource taking almost two minutes looks like a hang when every other
> single-resource change in this course finishes in seconds. Let it run.

> **Teaching note:** This is the IaC version of an operational change. In production, a Terraform plan that says "1 to destroy" on a zone association is the kind of diff a reviewer should catch *before* apply. Reading the plan is a network-engineering control, not a formality.

---

## Task 3: Reproduce the Symptom from Spoke A

> [!CAUTION]
> **The failure in this task is SUPPOSED to happen. You have not broken anything.**
>
> `app.lab.internal` will **fail to resolve** from spoke A - no answer, or
> `NXDOMAIN`. That is the symptom you came here to reproduce, and it means the
> fault injected in Task 2 is working.
>
> Do not re-run `terraform apply` and do not go looking for a typo in the name.
> Task 4 has you resolve the *same* name from spoke B, where it still works -
> that contrast is what proves this is a DNS **scope** problem and not a broken
> resolver, a routing fault, or a security group.

5. **Start** a Session Manager shell on the spoke A instance (no SSH, no key pair - this is the only access path in a no-IGW/no-NAT design):

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

6. **Inside the session**, try to resolve the name. `getent` (built into glibc) and `nslookup` are both preinstalled on Amazon Linux 2023 - use them. Do **not** `dnf install` anything here: this instance has no NAT and no internet gateway, so a package install cannot reach the repos and just **hangs** (Ctrl-C to escape if you try it).

    ```bash
    getent hosts app.lab.internal; echo "exit=$?"
    nslookup app.lab.internal
    command -v dig >/dev/null && dig +short app.lab.internal || echo "(dig not installed - skipping; no internet to add it)"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** `getent` returns no output and `exit=2` (name not found). `nslookup` (using the VPC resolver at `10.106.1.2`) reports `** server can't find app.lab.internal: NXDOMAIN`. If `dig` happens to be installed it prints nothing; otherwise you see the skip message. The name does not resolve from spoke A.

7. **Confirm the instance itself is otherwise healthy** - this rules out a broken resolver or a dead endpoint. From the same session:

    ```bash
    getent hosts ssm.${AWS_REGION:-us-east-1}.amazonaws.com >/dev/null && echo "SSM endpoint resolves - resolver is fine"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

    (Your session exists at all because the SSM interface endpoints and their DNS are working. If the resolver were broken, you would not have a shell here.)

8. **Type** `exit` to leave the session.

---

## Task 4: Prove It Is Scope, Not the Resolver - Test Spoke B

9. **Back on the deploy box**, start a session on the spoke B instance and resolve the same name. If you skipped the `exit` in step 8 you are still inside **spoke A** - confirm before you run this:

    ```bash
    hostname -I
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

    A `10.106.250.x` address means you are on the deploy box and can continue. A `10.106.1.x` address means you are still inside spoke A - type `exit` first.

    ```bash
    aws ssm start-session --target "$B_ID" --region "$REGION"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

    > **Why this matters.** Session Manager sessions do not nest. Run the command
    > above from *inside* spoke A and it does not refuse - it **hangs and then
    > times out**, because that instance has no route to the SSM API (its
    > endpoints serve its own agent only) and its role carries just
    > `AmazonSSMManagedInstanceCore`. A timeout here means wrong shell, not a
    > broken instance.

    Inside the session:

    ```bash
    getent hosts app.lab.internal
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** Spoke B prints `10.106.1.x  app.lab.internal` - it resolves correctly. Same zone, same record, same Transit Gateway, opposite result. Because spoke B works and spoke A does not, the problem is **not** the zone, the record, or DNS in general. It is that spoke A cannot *see* the zone. That points squarely at the zone-to-VPC association.

10. **Type** `exit` to leave the session.

---

## Task 5: Confirm the Root Cause in Route 53

> [!IMPORTANT]
> **Everything from here runs on the DEPLOY BOX, not inside a spoke.** If you
> skipped the `exit` above you are still in the spoke, and these commands fail in
> confusing ways rather than refusing: `terraform.tfvars` is "No such file",
> `$REGION` is empty so endpoint URLs come out malformed with a missing region
> (`ec2..amazonaws.com`), and any
> AWS call **hangs and times out** because a spoke has no route to the AWS APIs.
>
> One command settles it:
>
> ```bash
> hostname -I
> ```
>
> `10.106.250.x` = deploy box, carry on. `10.106.1.x` or `10.106.2.x` = still in a
> spoke, type `exit` first.


You can confirm the missing association from the console or the CLI. Use whichever you prefer; both read the same truth.

**Console path:**

> [!IMPORTANT]
> **Every student's zone is called `lab.internal` - pick yours by Description, not by name.**
>
> The account is shared, so **Hosted zones** lists one `lab.internal` per student.
> They are genuinely separate zones and they do not conflict: a private hosted
> zone only answers queries from the VPCs it is associated to, and yours is
> associated only to your VPCs. But the **Name** column cannot tell them apart.
>
> Identify yours by the **Description** column, which reads
> `io106-<your_id> private zone`. If you want to be certain, print your zone id
> first and match it in the **Hosted zone ID** column:
>
> ```bash
> terraform output -raw lab_internal_zone_id
> ```
>
> Opening another student's zone is harmless - it is read-only here - but you
> would be looking at *their* VPC associations and would conclude the fault is
> somewhere it is not.

11. **Open** the **Route 53** console, go to **Hosted zones**, and click the `lab.internal` row whose **Description** is `io106-<your_id> private zone` (it is marked **Private hosted zone**). At the top of the page, **expand the _Hosted zone details_ section** - it is collapsed by default, and the associated VPCs are hidden inside it.

12. In the expanded **Hosted zone details**, read the **VPCs** list - these are the VPCs allowed to resolve names in this zone. (You can also click **Edit** to see the full editable set.)

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
> ID=$(awk -F'"' '/^[[:space:]]*student_id/{print $2}' terraform.tfvars)
> aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=io106-$ID-*" --query 'Vpcs[].[Tags[?Key==`Name`].Value|[0],VpcId]' --output text
> ```
>
> The spoke A VPC (`io106-<id>-spoke_a-vpc`) is absent from the zone's VPC list. Diagnosis confirmed: `aws_route53_zone_association.spoke_a` is missing.

---

## Task 6: Fix It in Terraform

You have two ways to restore the association. The **pedagogical fix** edits the source of truth so the repair is permanent and reviewable - that is how SYF operates. (A fast reset alternative is noted at the end.)

**What `count` actually does, and why deleting it is the fix**

In Terraform, `count` says **how many copies of this resource should exist**. It is not a flag or a condition on the resource's behaviour - it decides whether the resource exists at all:

| `count` value | What Terraform does |
|---|---|
| `1` | Create exactly one of this resource |
| `0` | Create **none** - and if one already exists, **destroy it** |

The line in your file is a conditional that evaluates to one of those two numbers:

```hcl
count = local.is_lab3 ? 0 : 1
```
<!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

Read it as: *"if `is_lab3` is true, then `0`, otherwise `1`."* And `local.is_lab3` is simply `var.scenario == "lab3"`. So when you ran `terraform apply -var scenario=lab3` in Task 2, that line evaluated to `0`, Terraform concluded this resource should not exist, and **destroyed the association** - which is exactly the `1 to destroy` you read in the plan. The zone, the record, the routing and the security groups were never touched; only this one association was counted down to zero.

**Deleting the line removes the conditional entirely.** A resource with no `count` is simply always created, once. The association can then never be counted down to zero again, no matter what `scenario` is set to - which is why the next step applies with no `-var` flag at all and the fix still holds. That is what makes it a *repair* rather than a reset: you have changed what the code says should exist, not just which switch is flipped.

<!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

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

15. **Apply.** Drop the `-var scenario` flag - with the `count` guard gone, the resource exists regardless of scenario, and omitting the flag returns `scenario` to its healthy default:

    ```bash
    terraform plan        # confirm: 1 to add (the restored association), 0 to destroy
    terraform apply
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

    Read the plan: Terraform should report it will **add** one resource, the spoke A zone association.

16. **Type** `yes` to apply.

> **Expected Result:** `Apply complete! Resources: 1 added.` Note that removing `count` changes the resource address from `aws_route53_zone_association.spoke_a[0]` back to `aws_route53_zone_association.spoke_a` - Terraform handles this transparently. Expect this apply to take **over a minute** (measured at 84s) - re-associating a Route 53 private zone is simply slow, the same as the removal in Task 2.

> **Unlike the IAM boundary in Lab 2, DNS resolution comes back immediately** once the association exists - there is no extra propagation wait. Measured here: the first `getent` after the apply already resolved. If the name still fails, the association genuinely is not there - re-check the plan output rather than waiting.

---

## Task 7: Re-Verify

17. **Confirm resolution is back** from spoke A. Start a session:

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ssm/ -->

    Then, **inside the session**, resolve the name and exit (paste these separately - the session is a new shell):

    ```bash
    getent hosts app.lab.internal
    exit
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

> **Expected Result:** Spoke A now prints `10.106.1.x  app.lab.internal`.

> [!IMPORTANT]
> **Everything from here runs on the DEPLOY BOX, not inside a spoke.** If you
> skipped the `exit` above you are still in the spoke, and these commands fail in
> confusing ways rather than refusing: `terraform.tfvars` is "No such file",
> `$REGION` is empty so endpoint URLs come out malformed with a missing region
> (`ec2..amazonaws.com`), and any
> AWS call **hangs and times out** because a spoke has no route to the AWS APIs.
>
> One command settles it:
>
> ```bash
> hostname -I
> ```
>
> `10.106.250.x` = deploy box, carry on. `10.106.1.x` or `10.106.2.x` = still in a
> spoke, type `exit` first.

18. **Run the full health check:**

    ```bash
    ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 3" -->

> **Expected Result:** `ALL CHECKS PASSED -- healthy baseline confirmed.` In particular, check 5 (`app.lab.internal resolves from spoke_a`) now passes. Because you removed the guard rather than just resetting the variable, the fix lives in the Terraform and survives the next apply.

> **Fast reset alternative.** If you only wanted to undo the scenario without editing code, `terraform apply -var scenario=healthy` re-creates the association too. The difference: that path leaves the `count` guard in place, so the fault could be re-injected. Editing the code is the durable fix; resetting the variable is the rehearsal-reset.

---

## Task 8 (Bonus): Reach the Shared Endpoint Across the Transit Gateway

> **Optional - approximately 10 minutes.** Everything in this task is **read-only**. There is no Terraform change and no fault to inject, so you can stop after Task 7 with a complete lab. Do this one if you want to see the central-endpoint pattern actually carry traffic, rather than only reading about it.

So far the interface endpoints have been *infrastructure* - the reason Session Manager works at all. This task makes one of them the subject. You will use the **shared STS endpoint in the Transit VPC**, prove that spoke A cannot reach it by the service's normal name, then reach it across the Transit Gateway by its endpoint-specific name.

This is the exact question to ask about any centralized endpoint: *routing* and *DNS* are two separate problems, and PrivateLink only solves the first one for you.

19. **On the deploy box**, find your own shared endpoint and look at every DNS name it has. Scope the filter to your `student_id` - the `io106-*` tag prefix is shared with every other student in this account:

    ```bash
    MY_ID=$(grep -E '^[[:space:]]*student_id' terraform.tfvars | cut -d'"' -f2)
    echo "my student_id = $MY_ID"
    aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=tag:Name,Values=io106-$MY_ID-transit-sts" --query 'VpcEndpoints[0].DnsEntries[].DnsName' --output table
    ```
    <!-- source: https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html -->

> **Expected Result:** Four or five names. One **Regional** name like `vpce-0abc...-x1y2.sts.<region>.vpce.amazonaws.com`, one **zonal** name per AZ (same thing with `-<region><letter>` appended to the first label), and - last - the plain public name `sts.<region>.amazonaws.com`. That final entry is the record from the hidden, AWS-managed private hosted zone, and it is the one that only works inside the Transit VPC.

20. **Capture** the Regional endpoint name and print a block to paste into the spoke. The `grep -v` drops the zonal names, keeping the Regional one:

    ```bash
    STS_DNS=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=tag:Name,Values=io106-$MY_ID-transit-sts" --query 'VpcEndpoints[0].DnsEntries[].DnsName' --output text | tr '\t' '\n' | grep '^vpce-' | grep -v -- "-${REGION}[a-z]\." | head -1)
    echo "REGION=$REGION"
    echo "STS_DNS=$STS_DNS"
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-vpc-endpoints.html -->

> **Expected Result:** Two `NAME=value` lines, the second ending in `.vpce.amazonaws.com`. If `STS_DNS` is empty, re-check that `MY_ID` printed your real student id in step 19.

21. **Copy both lines** from step 20, then start a session on spoke A and paste them in. They do not carry across the session boundary - a new shell has none of your variables:

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ssm/ -->

> [!CAUTION]
> **The next command is supposed to fail.** You are about to call STS by its normal public name from a VPC that has no internet gateway and no NAT. It will hang for the full timeout and then error. That failure is the finding, not a mistake - do not try to fix it.

22. **Inside the spoke A session**, paste your two `NAME=value` lines from step 20, then resolve and call the service **by its public name**:

    ```bash
    getent hosts sts.$REGION.amazonaws.com
    aws sts get-caller-identity --region "$REGION" --cli-connect-timeout 5 --no-cli-pager
    ```
    <!-- source: https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html -->

> **Expected Result:** `getent` returns a **public** address (something like `3.x.x.x` or `52.x.x.x`) - *not* a `10.106.x.x` address. The spoke's resolver has no knowledge of the Transit VPC's hidden endpoint zone, so it answers from public DNS. The `aws sts` call then fails with a connect timeout (`Could not connect to the endpoint URL` after a few retries), because spoke A has no route to a public address. **Routing to the endpoint is fine; DNS sent you somewhere else entirely.**

23. **Still inside spoke A**, now use the endpoint-specific name instead, then leave the session:

    ```bash
    getent hosts "$STS_DNS"
    aws sts get-caller-identity --endpoint-url "https://$STS_DNS" --region "$REGION" --no-cli-pager
    exit
    ```
    <!-- source: https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html -->

> **Expected Result:** `getent` returns a **`10.106.0.x`** address - an endpoint network interface in the *Transit* VPC, not in spoke A. The `aws sts` call then succeeds and prints JSON containing the spoke A instance role ARN. That call left spoke A, crossed the **Transit Gateway** into the Transit VPC, hit a centrally-owned interface endpoint, and came back - with no internet gateway and no NAT anywhere in the path. This is the central endpoint account pattern working end to end.
>
> Why this one resolved: the Regional and zonal `vpce.amazonaws.com` names are ordinary **public** DNS records ("the DNS records that we create for your interface VPC endpoint are public"), so spoke A's resolver can answer them - and the address they return is private and routable over the transit.

> [!IMPORTANT]
> **You are back on the DEPLOY BOX** after the `exit` above. Confirm with `hostname -I` if you are unsure: `10.106.250.x` = deploy box, `10.106.1.x` = still in spoke A.

### What this means for designing shared endpoints

Students usually ask the obvious follow-up: *could we put an S3 endpoint in the Transit VPC and reach it from the spokes the same way?* The answer depends entirely on which **type** of endpoint, and this is worth knowing before you design it:

| | Gateway endpoint (S3, DynamoDB) | Interface endpoint (PrivateLink) |
|---|---|---|
| **Mechanism** | A prefix-list route in the route tables you select | Elastic network interfaces with private IPs in your subnets |
| **Reachable from another VPC over Transit Gateway or peering** | **No** - "do not allow access from on premises"; "do not allow access from another AWS Region" | **Yes** - "allow access from a VPC in another AWS Region by using VPC peering or AWS Transit Gateway" |
| **DNS** | Uses the same public S3 names | **Requires** endpoint-specific names, as you just saw |
| **Cost** | Not billed | Billed per AZ-hour plus per GB |

So a **gateway** endpoint can never be centralized - it only ever serves the VPC it is attached to, which is why a shared-endpoint design uses **interface** endpoints even for S3, and accepts the cost.

And to make the plain name work from a spoke - so applications need no `--endpoint-url` change - you add exactly what you fixed in Task 6: **your own** Route 53 private hosted zone for `sts.<region>.amazonaws.com`, holding an alias to the endpoint, **associated with the spoke VPCs**. You cannot associate AWS's hidden zone, but nothing stops you from creating your own and scoping it yourself. The whole centralized-endpoint model is a routing decision plus a zone-association decision - and the zone association is the half that silently does nothing when you get it wrong.

---

## Knowledge Checks

**Question 1.** Spoke B resolves `app.lab.internal` but spoke A returns NXDOMAIN, even though both spokes share the same Transit Gateway and the record never changed. Why does association - not routing or the record itself - explain this difference?

<details><summary>Answer</summary>

A Route 53 **private** hosted zone only answers DNS queries that originate in a VPC explicitly **associated** to the zone. The Transit Gateway carries IP traffic *after* a name resolves to an address; it has nothing to do with resolution. The `A` record exists in the zone for every associated VPC. Spoke B is associated, so its VPC resolver sees the zone and answers. Spoke A's association was removed, so spoke A's resolver has no knowledge of `lab.internal` and returns NXDOMAIN. The fault is the *scope* of the zone, not its contents or the network path.
</details>

**Question 2.** During diagnosis you confirmed the spoke A instance could still reach its SSM endpoints and you had a working Session Manager shell. Why does that observation rule out a broken VPC resolver or a security-group problem as the cause?

<details><summary>Answer</summary>

Session Manager only works because the SSM interface endpoints resolve via private DNS and the endpoint security groups permit the instance on 443. If the VPC's `.2` resolver were down, the SSM endpoint names would not resolve and the agent could not connect - you would have no shell. If a security group were blocking, the endpoint connection would fail. The shell working proves the resolver and the endpoint SGs are healthy, which isolates the failure to something specific to the `lab.internal` zone - its association to spoke A.
</details>

**Question 3.** In the Terraform, what does `count = local.is_lab3 ? 0 : 1` do to the `aws_route53_zone_association.spoke_a` resource, and why was the association written as a separate resource from the `aws_route53_zone` itself?

<details><summary>Answer</summary>

`count = local.is_lab3 ? 0 : 1` evaluates to `0` when the scenario is `lab3` (because `local.is_lab3` is `true`), and a resource with `count = 0` is not created - so the spoke A association is absent in the `lab3` state and present otherwise. The association is a separate `aws_route53_zone_association` resource (rather than a `vpc {}` block inside `aws_route53_zone`) precisely so that one VPC's association can be added or removed without recreating or modifying the zone. This is the standard Terraform pattern for centrally owned private zones that many VPCs attach to over time - the kind of model SYF runs from its central endpoint account.
</details>

**Question 4 (bonus task).** A colleague proposes centralizing S3 access for all spokes by creating a single **gateway** endpoint in the Transit VPC and letting the spokes reach it over the Transit Gateway. Why will this not work, and what are the two changes that make a centralized endpoint usable from a spoke by its normal service name?

<details><summary>Answer</summary>

A gateway endpoint is implemented as a **route**: creating one adds an AWS-managed prefix-list entry to the route tables you select, inside that VPC. It only serves instances in subnets whose route tables carry that entry, so it cannot be consumed from another VPC at all - the docs state plainly that gateway endpoints "do not allow access from on premises" and "do not allow access from another AWS Region." There is nothing to route *to* from the spoke; the endpoint is not an address, it is a routing rule in someone else's route table. A centralized design must use an **interface** endpoint, which is real network interfaces with private IPs and is explicitly supported "from a VPC in another AWS Region by using VPC peering or AWS Transit Gateway."

The two changes are (1) **routing** - the spoke needs a route to the endpoint's VPC CIDR via the Transit Gateway, and the endpoint's security group must permit 443 from the spoke CIDR; and (2) **DNS** - because the endpoint's own private DNS is an AWS-managed hidden zone scoped to the endpoint's VPC and cannot be associated elsewhere, you create your **own** Route 53 private hosted zone for the service name, with an alias to the endpoint, and associate it with the spoke VPCs. Without (1) it is unreachable; without (2) it is reachable but the name resolves to the public service address and traffic goes nowhere - which is precisely what you observed in step 22.
</details>

---

## Lab Summary

You took a healthy private-DNS design, injected a single realistic fault by switching the Terraform stack into `lab3`, and proved the cause methodically: NXDOMAIN from spoke A, clean resolution from spoke B, and a missing VPC in the Route 53 zone's association list. You then fixed it the SYF way - by restoring the `aws_route53_zone_association.spoke_a` resource in Terraform and re-applying - and confirmed the repair with `./verify.sh`.

The transferable lesson: with centralized VPC endpoints and Route 53 private zones, "name doesn't resolve in one VPC but works in another" almost always means a missing or mis-scoped zone association, not a broken resolver. Check association scope first.

**Next:** Lab 4 is the troubleshooting capstone. You will diagnose a *compound* connectivity failure - two independent faults at once - using VPC Flow Logs and Reachability Analyzer from the read-only network-operations role, and fix both in Terraform.

---

## Resources

- [Amazon Route 53 - Working with private hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [Amazon Route 53 - Associating a VPC with a private hosted zone](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-associate-vpcs.html)
- [Amazon VPC - Interface VPC endpoints (AWS PrivateLink)](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html)
- [AWS PrivateLink - Access AWS services (private DNS, DNS hostnames, DNS resolution)](https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html) - the Task 8 reference for why private DNS is VPC-scoped
- [AWS PrivateLink - Gateway endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html) - gateway vs interface endpoint behaviour
- [AWS PrivateLink for Amazon S3 - Types of VPC endpoints for Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/privatelink-interface-endpoints.html) - the gateway/interface comparison table quoted in Task 8
- [AWS Systems Manager - Starting a session (Session Manager)](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)
- [Terraform - The `count` meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
