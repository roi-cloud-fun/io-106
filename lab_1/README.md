# Lab 1: Hub-Spoke Transit and Segmentation

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 1 - SYF AWS Network Architecture |
| **Duration** | 40 minutes |
| **Difficulty** | Advanced |
| **Prerequisites** | Lab 0 completed; your stack deployed and `verify.sh` green. Familiarity with VPC route tables and Transit Gateway routing. |
| **Builds On** | Lab 0. You reuse the same per-student stack; this lab injects one fault into it and you repair it. |

---

## Lab Overview

A hub-and-spoke transit only works if both sides of a path have a route to each other through the hub. When one direction's route is missing, the symptom looks like a firewall problem but is really a routing problem - and the two are diagnosed with different tools. In this lab you inject exactly that fault, then use **VPC Reachability Analyzer** to prove it is a routing gap (not a security group), corroborate with **VPC Flow Logs**, and repair the route by editing Terraform.

The fault: `scenario=lab1` removes spoke A's VPC route to spoke B's CIDR (`10.106.2.0/24`) via the Transit Gateway. Spoke A's packets to spoke B have nowhere to go, so they never even reach the hub. You will restore that one route.

> **Aviatrix note:** This lab uses AWS Transit Gateway. In your environment the hub-and-spoke transit is **Aviatrix** (Aviatrix Transit Gateway / Spoke Gateways), managed by the network team - the concepts map directly; the management plane differs. The spoke VPC route table you repair here is the AWS substrate that the **Aviatrix Controller** programs centrally as a segmentation/route policy. Doing it by hand is what makes the failure visible; in production you would adjust the policy in the Controller, not edit a route table directly.

---

## Scenario

A developer reports that an application in spoke A can no longer reach a service in spoke B - connections "just hang." Nothing was deployed to either instance, so the application team suspects the network. You own the transit layer. Your job is to prove where the packet dies, name the exact resource at fault, fix it as code, and confirm the path is restored - the same loop you would run against the Aviatrix overlay in production, except here you can see every primitive.

---

## Learning Objectives

By the end of this lab, you will:

- Inject a single, realistic routing fault into your stack with `terraform apply -var scenario=lab1` and reproduce the symptom from a private instance.
- Use **VPC Reachability Analyzer** to distinguish a routing failure from a security-group failure, reading the explanation code that names the missing route.
- Corroborate the diagnosis with the spoke A **VPC route table** and **VPC Flow Logs**.
- Repair the route by editing the Terraform `count` guard and re-applying, proving you fixed the resource rather than just resetting a toggle.
- Map the spoke route table and TGW attachment to their Aviatrix equivalents.

---

## Task 1: Confirm a Healthy Starting Point

> **Where you run everything in this lab.** All `terraform`, `verify.sh`, and `aws` commands run on your **deploy box** (`io106-<your_id>-deploy`), from the Terraform module directory `~/io-106/lab_environment/lab_env_student` - not your laptop, and not inside a spoke instance. The only commands that run inside a spoke instance are the ones explicitly labelled `# inside the spoke A session`.
>
> SSM sessions time out after a period of inactivity (about 20 minutes by default). If your session dropped since Lab 0, reconnect before continuing - **Systems Manager > Session Manager > Start session** on `io106-<your_id>-deploy` - then return to the module directory. Note that shell variables (like the `$A_ID` and `$B_IP` you set below) do **not** survive a reconnect: if you reconnect mid-lab, re-run the capture block in Task 2.
>
> ```bash
> cd ~/io-106/lab_environment/lab_env_student
> ```

1. **From the module directory**, confirm your baseline is still healthy before you break it (the `cd` is safe to re-run if you just reconnected):

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    bash ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

**Expected Result:** `ALL CHECKS PASSED`. If not, re-run `terraform apply` (healthy) and re-verify before continuing.

---

## Task 2: Inject the Fault

2. **Apply** the lab1 scenario from the module directory (`~/io-106/lab_environment/lab_env_student`). This toggles exactly one real resource - spoke A's route to spoke B - off:

    ```bash
    terraform apply -var scenario=lab1
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

    Watch the plan. You should see `Plan: 0 to add, 0 to change, 1 to destroy` (or it may show as a replace of the route resource's count). Terraform tells you up front it is removing a single route. Type `yes`.

3. **Capture** the probe values you will use repeatedly:

    ```bash
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_IP=$(terraform output -raw spoke_b_instance_private_ip)
    echo "spoke A instance: $A_ID   spoke B IP: $B_IP"
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

**Expected Result:** Apply completes with `1 destroyed`. The `$A_ID` and `$B_IP` variables hold your spoke A instance ID and spoke B's private IP.

---

## Task 3: Reproduce the Symptom

4. **Open** a Session Manager shell on the spoke A instance:

    ```bash
    aws ssm start-session --target "$A_ID"
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

5. **From inside the session**, try to reach spoke B (use the `$B_IP` value printed in Task 2):

    ```bash
    # inside the spoke A session
    ping -c 4 -W 2 SPOKE_B_IP
    exit
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

**Expected Result:** The ping times out - 100% packet loss, no replies. This is the developer's "it just hangs." Note that the symptom alone does not tell you whether a route, a security group, or the instance is at fault. The next task settles that.

---

## Task 4: Diagnose with Reachability Analyzer

Reachability Analyzer evaluates the *configured* path - routes, security groups, attachments - without sending a packet, and tells you the first hop that blocks it. It is the fastest way to separate "no route" from "blocked by SG."

6. **Open** the AWS console and navigate to **Network Manager > Reachability Analyzer**. (AWS moved this tool out of the VPC console - if you look for it under VPC you will not find it.)

7. **Click** **Create and analyze path** and set:
    - **Source type:** Instance, **Source:** your spoke A instance (`io106-<id>-spoke-a`).
    - **Destination type:** Instance, **Destination:** your spoke B instance (`io106-<id>-spoke-b`).
    - **Protocol:** ICMP (or TCP - the routing verdict is the same).

8. **Click** **Create and analyze path** and wait for the analysis to complete (a few seconds to a minute).

**Expected Result:** The path returns **Not reachable**. The explanation identifies the break as **no route to the destination in the source VPC route table** - the analyzer points at spoke A's route table, not at any security group. That distinction is the whole diagnosis: a security-group fault would show the packet reaching spoke B's ENI and being rejected there; here it never leaves spoke A.

---

## Task 5: Corroborate with the Route Table and Flow Logs

A good engineer confirms the tool's verdict against the resource itself.

9. **Inspect** spoke A's route table directly. In the console go to **VPC > Route tables**, select `io106-<id>-spoke_a-rt`, and open the **Routes** tab. Or from the CLI:

    ```bash
    aws ec2 describe-route-tables \
      --filters "Name=tag:Name,Values=io106-<id>-spoke_a-rt" \
      --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Target:TransitGatewayId}' \
      --output table
    ```
    <!-- source: facts_extracted_v2.md §"Route Tables" -->

    You should see routes for the local CIDR (`10.106.1.0/24`) and for the transit VPC (`10.106.0.0/24` via the TGW), but **no** entry for `10.106.2.0/24` (spoke B). That missing line is the fault.

10. **Cross-check** with Flow Logs (optional but instructive). In **CloudWatch > Logs Insights**, select your flow log group (`terraform output -raw flow_log_group`) and run:

    ```
    fields @timestamp, srcAddr, dstAddr, action
    | filter dstAddr like /10.106.2./
    | sort @timestamp desc
    | limit 20
    ```

    Because spoke A has no route to `10.106.2.0/24`, the packets are dropped before egress - you will see spoke A's attempts with no corresponding ACCEPT on spoke B's interface. (Contrast this with Lab 4, where a security group produces explicit REJECT records on the destination ENI.)

**Expected Result:** Spoke A's route table is missing the `10.106.2.0/24 -> tgw-...` route. Reachability Analyzer, the route table, and Flow Logs now agree: this is a routing gap on the source side, not a firewall issue.

---

## Task 6: Fix It in Terraform

The route is defined in `network.tf` as `aws_route.spoke_a_to_spoke_b`, guarded by `count = local.is_lab1 ? 0 : 1`. Under `scenario=lab1` that guard is `0`, so the route does not exist. You will repair the resource so the route exists **regardless of scenario** - that proves you fixed the network, not just flipped the switch back.

11. **In the module directory, edit** `network.tf`. Find the `aws_route "spoke_a_to_spoke_b"` block and change its count from the guard to a constant `1`:

    ```hcl
    resource "aws_route" "spoke_a_to_spoke_b" {
      count = 1                       # was: count = local.is_lab1 ? 0 : 1

      route_table_id         = aws_route_table.this["spoke_a"].id
      destination_cidr_block = var.spoke_b_cidr
      transit_gateway_id     = aws_ec2_transit_gateway.hub.id

      depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
    }
    ```

12. **Preview** the fix with the scenario still set to lab1 - this is the key step that demonstrates the repair:

    ```bash
    terraform plan -var scenario=lab1
    ```
    <!-- source: facts_extracted_v2.md §"Transit Gateway" -->

    The plan should show `1 to add` - Terraform will create the route even though `scenario=lab1`, because your edit no longer lets the guard delete it.

13. **Apply** the fix:

    ```bash
    terraform apply -var scenario=lab1
    ```
    <!-- source: facts_extracted_v2.md §"Transit Gateway" -->

> **Note:** The fast reset is `terraform apply -var scenario=healthy`, which also restores the route. The point of editing the resource is to practice the real workflow - in production you repair the configuration, you do not have a "make it healthy" switch.

**Expected Result:** Apply completes with `1 added`. Spoke A's route table now contains `10.106.2.0/24 -> tgw-...`.

---

## Task 7: Re-Verify

14. **Re-run** Reachability Analyzer (Task 4) - or just re-test from the instance:

    ```bash
    aws ssm start-session --target "$A_ID"
    # inside the session:
    ping -c 4 -W 2 SPOKE_B_IP
    exit
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

15. **Run** the health check (if you just exited a spoke session, you are back on the deploy box):

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    bash ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 1" -->

**Expected Result:** The ping now succeeds (replies, 0% loss), Reachability Analyzer returns **Reachable**, and `verify.sh` reports the spoke A -> spoke B check as PASS.

---

## Aviatrix Mapping

| What you touched (AWS native) | Aviatrix equivalent in SYF's environment |
|---|---|
| `aws_ec2_transit_gateway` (hub) | Aviatrix Transit Gateway |
| Spoke VPC TGW attachment | Aviatrix Spoke Gateway peering |
| Spoke A VPC route table entry to spoke B | A route/segmentation policy the Aviatrix Controller programs centrally |
| Manually adding the missing route | Adjusting the segmentation policy in the Aviatrix Controller |

The failure mode is identical; only the management plane differs. In production you would not edit a route table by hand - you would see the gap in the Controller's policy and fix it there - but knowing what the underlying route must look like is exactly what lets you tell the network team precisely what is wrong.

---

## Knowledge Check

**Question 1:** Reachability Analyzer returned "Not reachable - no route to destination in the source route table," and Flow Logs showed no REJECT on spoke B's interface. Why do those two observations together rule out a security group as the cause?

<details><summary>Answer</summary>

> **Answer:** A security group only acts on packets that actually arrive at an interface. If the source VPC route table has no route to the destination CIDR, the packet is dropped at the source before it is ever forwarded to the TGW - it never reaches spoke B's ENI, so no security group is ever evaluated and no REJECT can appear. Reachability Analyzer naming the *source route table* (not an SG) plus the absence of any REJECT on the destination both point to routing, upstream of any firewall decision.
</details>

**Question 2:** You fixed the fault by editing `count` to `1` and running `terraform apply -var scenario=lab1` - leaving the lab1 scenario active. Why is that a stronger demonstration of the fix than simply running `terraform apply -var scenario=healthy`?

<details><summary>Answer</summary>

> **Answer:** `scenario=healthy` resets every guarded resource at once, so it would mask whether you understood the specific fault. Editing the resource and applying with `scenario=lab1` still set proves the route now exists independently of the scenario toggle - you repaired the actual configuration, which is what you would do in production where there is no "healthy" switch to fall back on.
</details>

**Question 3:** This lab only broke spoke A's outbound route to spoke B. In a real hub-and-spoke, why would you still check the return path (spoke B back to spoke A) before declaring connectivity fully restored?

<details><summary>Answer</summary>

> **Answer:** Transit routing is directional - each spoke's route table must independently carry a route to the other's CIDR via the hub. A working forward route does not imply a working return route; ICMP echo replies (or TCP ACKs) need spoke B to have a route back to `10.106.1.0/24`. In this lab the return route was intact, so ping succeeded - but Lab 4 deliberately breaks a return route to make exactly this point.
</details>
---

## Summary

You injected a single routing fault, proved with Reachability Analyzer that it was a missing route (not a security group), corroborated it against the spoke A route table and Flow Logs, and repaired the route as code. You also saw how this AWS-native route maps to an Aviatrix segmentation policy in SYF's production overlay.

## Completion Checklist

- [ ] Healthy baseline confirmed before injecting the fault
- [ ] `scenario=lab1` applied; symptom reproduced (ping hangs)
- [ ] Reachability Analyzer returned Not reachable - no route in source route table
- [ ] Missing `10.106.2.0/24` route confirmed in spoke A's route table
- [ ] `network.tf` edited (`count = 1`) and applied with `scenario=lab1`
- [ ] Ping succeeds, Reachability Analyzer returns Reachable, `verify.sh` PASS

## Next Steps

In **Lab 2: Cross-Account Access Patterns**, you move from the data plane to the access plane: a `network-operations` role whose trust policy has been pointed at the wrong account. You will diagnose the `AccessDenied` with CloudTrail, read the trust policy, and repair it - the cross-account pattern behind SYF's read-only network visibility role.

---

## Resources

- [VPC Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html)
- [Transit Gateway routing](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-route-tables.html)
- [VPC route tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [VPC Flow Logs in CloudWatch Logs Insights](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-cwl.html)
- [Terraform - the count meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
