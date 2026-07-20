# Lab 4: Network Troubleshooting

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 4 - Network and Access Troubleshooting |
| **Duration** | 45 minutes |
| **Difficulty** | Advanced (capstone) |
| **Prerequisites** | Lab 0 deployed and `./verify.sh` all-PASS on the healthy baseline. Labs 1-3 completed (you reuse role assumption from Lab 2 and Flow Logs introduced in Lab 0). AWS CLI v2, `session-manager-plugin`, `terraform` >= 1.10, and `jq` pre-installed on your deploy instance. |
| **Builds On** | Lab 0 (your deployed `io106-<student_id>-` stack) and Lab 2 (assuming the `network-operations` role). This lab switches the same stack into the `lab4` fault state. |

---

## Lab Overview

This is the troubleshooting capstone. Everything you have built and broken so far - Transit Gateway routing (Lab 1), the cross-account read-only `network-operations` role (Lab 2), and private DNS (Lab 3) - comes together here. The `lab4` scenario injects a **compound failure**: spoke A cannot reach spoke B, and there is **more than one** root cause. You will diagnose methodically, using the right tool for each layer, from the read-only visibility role a SYF network engineer actually operates with.

The discipline this lab teaches: when a path is broken, do not stop at the first fault you find. Confirm you have found *every* fault before you declare victory. Fixing one of two faults leaves the path just as broken - and burns a change window for nothing.

> **Aviatrix disclaimer.** This lab uses AWS Transit Gateway. In your environment the hub-and-spoke transit is **Aviatrix** (Aviatrix Transit Gateway / Spoke Gateways), managed by the network team - the concepts map directly; the management plane differs. The spoke route tables and security groups you diagnose here are the AWS substrate that the Aviatrix Controller programs in production. Doing it by hand is what makes each fault visible.

---

## Scenario

An application on **spoke A** can no longer reach a service on **spoke B**. Pings and connections time out. The on-call network engineer has read-only access through the **network-operations role** and must find the root cause before raising a change. Earlier in the day someone "tidied up" security groups and route tables. There may be more than one problem. Find them all, then hand back an exact, minimal Terraform fix.

This is deliberately compound because real outages usually are. A single missing rule is a Lab 1; production incidents are two or three small things that line up badly.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Operate a troubleshooting investigation entirely from a read-only `network-operations` role using temporary STS credentials.
- Use **VPC Flow Logs** to find where a packet is actually dropped (an `ACCEPT`/`REJECT` verdict at a specific ENI) and attribute a `REJECT` to a security group.
- Use **VPC Reachability Analyzer** to statically prove a path is broken and read the explanation code that names the responsible resource (for example, a missing route).
- Recognise a compound fault and confirm *both* causes before remediating.
- Fix both faults in Terraform (a security-group ingress rule and a spoke route) and re-verify with `./verify.sh`.

---

## How the Fault Is Injected (Terraform)

The `lab4` scenario removes **two** independent resources at once. Each is gated by `count = local.is_lab4 ? 0 : 1`, which evaluates to `0` (resource not created) only when you pass `-var scenario=lab4`:

```hcl
# security_groups.tf - spoke B's instance SG ingress for ICMP from spoke A
resource "aws_vpc_security_group_ingress_rule" "spoke_b_icmp_from_a" {
  count = local.is_lab4 ? 0 : 1            # <-- FAULT 1 removed in lab4

  security_group_id = aws_security_group.spoke_b_instance.id
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = var.spoke_a_cidr     # 10.106.1.0/24
}
```
<!-- source: facts_extracted_v2.md §"Security Groups" -->

```hcl
# network.tf - spoke B's RETURN route to spoke A via the Transit Gateway
resource "aws_route" "spoke_b_to_spoke_a" {
  count = local.is_lab4 ? 0 : 1            # <-- FAULT 2 removed in lab4

  route_table_id         = aws_route_table.this["spoke_b"].id
  destination_cidr_block = var.spoke_a_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
}
```
<!-- source: facts_extracted_v2.md §"Route Tables" -->

The two faults sit at different layers and surface to different tools:

- **Fault 1 (security group):** the ICMP packet from spoke A reaches spoke B's ENI, where the security group has no rule to admit it, so it is dropped. This shows up as a **`REJECT`** in spoke B's **Flow Logs**.
- **Fault 2 (route):** even a reply from spoke B has no route back to spoke A's CIDR, because spoke B's VPC route table is missing the `10.106.1.0/24` entry. **Reachability Analyzer** on the `spoke_b -> spoke_a` path reports **no route to destination**.

Fix only one and the path stays down. That is the whole point.

---

## Task 1: Capture Outputs and Inject the Fault

1. **Reconnect** to your deploy instance via SSM (`io106-<your_id>-deploy`), then **change** into the stack directory and capture the values you need (these read local state, so they work before and after assuming a role):

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    A_IP=$(terraform output -raw spoke_a_instance_private_ip)
    B_IP=$(terraform output -raw spoke_b_instance_private_ip)
    REGION=$(terraform output -raw region)
    NETOPS_ARN=$(terraform output -raw network_operations_role_arn)
    LOG_GROUP=$(terraform output -raw flow_log_group)
    echo "A=$A_ID/$A_IP  B=$B_ID/$B_IP  region=$REGION"
    echo "netops=$NETOPS_ARN  logs=$LOG_GROUP"
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

2. **Apply** the `lab4` scenario. Your `student_id` is already set in `terraform.tfvars` - do **not** pass `-var student_id` on the command line (a hardcoded id renames every resource and forces a destroy/recreate of your whole stack).

    ```bash
    terraform plan -var scenario=lab4     # ALWAYS read the plan first
    terraform apply -var scenario=lab4
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

    Read the plan. Terraform reports **two** resources destroyed - one security-group rule and one route:

    ```
    # aws_route.spoke_b_to_spoke_a[0] will be destroyed
    # aws_vpc_security_group_ingress_rule.spoke_b_icmp_from_a[0] will be destroyed
    Plan: 0 to add, 0 to change, 2 to destroy.
    ```

3. **Type** `yes` to apply.

> **Expected Result:** `Destroy complete! Resources: 2 destroyed.` The plan naming both resources is a hint, not the answer - in a real incident you do not get a plan that lists the faults. Treat the rest of this lab as if you did not see it.

---

## Task 2: Reproduce the Symptom

4. **Start** a Session Manager shell on spoke A and try to reach spoke B:

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```

    Then, **inside the session**, ping spoke B and exit (paste these separately - the session is a new shell; use the spoke B IP printed in Task 1):

    ```bash
    ping -c 3 -W 2 <B_IP>
    exit
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

> **Expected Result:** 100% packet loss - spoke A cannot reach spoke B. Symptom confirmed. Now you investigate from the read-only role, not from the instance.

---

## Task 3: Assume the network-operations Role

A SYF network engineer investigates with read-only visibility, not admin. Assume the `network-operations` role and work from its temporary credentials - exactly the pattern you exercised in Lab 2.

5. **Assume** the role and export the temporary STS credentials into your shell:

    ```bash
    CREDS=$(aws sts assume-role \
      --role-arn "$NETOPS_ARN" \
      --role-session-name lab4-troubleshoot \
      --query 'Credentials' --output json)

    export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)

    aws sts get-caller-identity --query Arn --output text
    ```
<!-- source: facts_extracted_v2.md §"Cross-Account IAM Roles" -->

> **Expected Result:** The ARN ends with `assumed-role/io106-<id>-network-operations/lab4-troubleshoot`. You are now operating with read-only network visibility plus the Reachability Analyzer permissions the role grants. You cannot change anything from here - that is intentional. Diagnosis is read-only; the fix happens back in Terraform with your own identity.

---

## Task 4: Find Fault 1 with VPC Flow Logs

VPC Flow Logs record an `ACCEPT` or `REJECT` verdict for traffic at each ENI. A `REJECT` on inbound traffic at spoke B's ENI means a security group dropped it.

6. **Query** the flow-log group for rejected ICMP (protocol `1`) destined for spoke B's IP. `filter-log-events` is permitted by the network-operations role:

    ```bash
    aws logs filter-log-events \
      --region "$REGION" \
      --log-group-name "$LOG_GROUP" \
      --filter-pattern "[version, account, eni, srcaddr=10.106.1.*, dstaddr=$B_IP, srcport, dstport, protocol=1, packets, bytes, start, end, action=REJECT, status]" \
      --query 'events[].message' --output text
    ```
<!-- source: facts_extracted_v2.md §"VPC Flow Logs" -->

    **Console path (equivalent).** Open **CloudWatch > Logs > Log Analytics**, **select your flow-log group first** (the `flow_log_group` output - `terraform output -raw flow_log_group`), set the time range to the **last 30 minutes**, and run this Logs Insights query (replace `<B_IP>` with your spoke B IP):

    ```
    fields @timestamp, srcAddr, dstAddr, protocol, action
    | filter action = "REJECT" and dstAddr = "<B_IP>" and protocol = 1
    | sort @timestamp desc
    | limit 20
    ```

    Look for rows where `srcAddr` is spoke A's IP and `action` is `REJECT`. (The console runs under your own sign-in, not the assumed CLI role, so Logs Insights works here even though the read-only role cannot run queries.)

> **Expected Result:** One or more flow-log records where `srcaddr` is the spoke A IP, `dstaddr` is the spoke B IP, `protocol` is `1` (ICMP), and the action field is **`REJECT`**. A `REJECT` at spoke B's ENI for traffic that arrived there means the packet got across the Transit Gateway and into spoke B's VPC, then was dropped by spoke B's **security group**. That is **Fault 1**: spoke B's instance SG is missing an ingress rule for ICMP from spoke A.

> **If you see no records yet:** VPC Flow Logs take up to ~10 minutes to deliver the first batch after an apply. Re-send a few pings from spoke A (Task 2) to generate fresh traffic, wait, and re-run. You can widen the pattern by dropping `dstaddr=$B_IP` to see all `REJECT`s in the group.

7. **Note the asymmetry.** Flow Logs told you *a packet reached spoke B and was rejected by policy*. It did **not** tell you anything about the return path. A less disciplined engineer adds the SG rule, re-tests, finds it still broken, and is confused. You are going to check the return path *before* you touch anything.

---

## Task 5: Find Fault 2 with Reachability Analyzer

Reachability Analyzer is static analysis of the network configuration - it proves whether a path *can* work and, when it cannot, names the resource at fault. Run it on the **return** path, `spoke_b -> spoke_a`.

8. **Create and run** the analysis on the return path. Reachability Analyzer accepts `tcp`/`udp` only (**not** `icmp`) - a missing route blocks every protocol, so `tcp` proves the routing fault just as well. The network-operations role grants the `NetworkInsights` actions for exactly this. **Run these three commands one at a time and confirm each id is populated before continuing** - an empty id means the previous call failed, so read its error before moving on:

    ```bash
    PATH_ID=$(aws ec2 create-network-insights-path \
      --region "$REGION" \
      --source "$B_ID" --destination "$A_ID" --protocol tcp \
      --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)
    echo "PATH_ID=$PATH_ID"          # expect nip-...  (empty = create failed; read the error above)
    ```

    Start the analysis (needs a valid `PATH_ID`):

    ```bash
    ANALYSIS_ID=$(aws ec2 start-network-insights-analysis \
      --region "$REGION" \
      --network-insights-path-id "$PATH_ID" \
      --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)
    echo "ANALYSIS_ID=$ANALYSIS_ID"  # expect nia-...  (empty = start failed, usually an empty PATH_ID)
    ```

    Wait a few seconds for it to finish, then read the result:

    ```bash
    sleep 8
    aws ec2 describe-network-insights-analyses \
      --region "$REGION" \
      --network-insights-analysis-ids "$ANALYSIS_ID" \
      --query 'NetworkInsightsAnalyses[0].{Status:Status,Reachable:NetworkPathFound,Explanation:Explanations[0].ExplanationCode}' \
      --output table
    ```

    (If `Status` shows `running`, wait a few more seconds and re-run the last command.)
<!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

> **Expected Result:** `Status` is `succeeded`, `Reachable` (NetworkPathFound) is `false`, and the explanation code names a missing route (for example `NO_ROUTE_TO_DESTINATION` / no route to destination in the source route table). That is **Fault 2**: spoke B's VPC route table has no route back to spoke A's CIDR (`10.106.1.0/24`) via the Transit Gateway. The return traffic has nowhere to go.

9. **(Optional) Confirm directly** that the route is missing by inspecting spoke B's route table - the role can describe it:

    ```bash
    aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=tag:Name,Values=io106-*-spoke_b-rt" \
      --query 'RouteTables[0].Routes[].DestinationCidrBlock' --output text
    ```
<!-- source: facts_extracted_v2.md §"Route Tables" -->

> **Expected Result:** The list includes spoke B's own CIDR and the transit CIDR (`10.106.0.0/24`) but **not** `10.106.1.0/24`. Two faults are now confirmed, at two layers, by two tools.

10. **Clean up** the analysis artifacts (tidy, and the role permits delete on these):

    ```bash
    aws ec2 delete-network-insights-analysis --region "$REGION" --network-insights-analysis-id "$ANALYSIS_ID" >/dev/null
    aws ec2 delete-network-insights-path --region "$REGION" --network-insights-path-id "$PATH_ID" >/dev/null
    ```
<!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

---

## Task 6: Drop the Role and Fix Both Faults in Terraform

Diagnosis is done from read-only. The fix happens with your own identity, in code.

11. **Unset** the temporary network-operations credentials so Terraform runs as your normal identity:

    ```bash
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    aws sts get-caller-identity --query Arn --output text   # confirm you are back to your own identity
    ```
<!-- source: facts_extracted_v2.md §"Cross-Account IAM Roles" -->

    The `Arn` must **not** contain `network-operations`. If you skip this `unset`, Terraform runs as the read-only role and `plan`/`apply` fail with a wall of `AccessDenied` errors naming `assumed-role/io106-<id>-network-operations` - for example *not authorized to perform `iam:ListRolePolicies` / `ssm:GetParameter` / `logs:ListTagsForResource`*. That is the role being read-only **by design** - it cannot even refresh all of the state, let alone change it. If you see those errors, you forgot to unset: run the two commands above and retry.

12. **Fix Fault 1.** Open `security_groups.tf`, find `aws_vpc_security_group_ingress_rule.spoke_b_icmp_from_a`, and **delete** its `count` line so the ingress rule is always created:

    ```hcl
    resource "aws_vpc_security_group_ingress_rule" "spoke_b_icmp_from_a" {
      security_group_id = aws_security_group.spoke_b_instance.id   # count guard removed
      ip_protocol       = "icmp"
      from_port         = -1
      to_port           = -1
      cidr_ipv4         = var.spoke_a_cidr
    }
    ```

13. **Fix Fault 2.** Open `network.tf`, find `aws_route.spoke_b_to_spoke_a`, and **delete** its `count` line so the return route is always created:

    ```hcl
    resource "aws_route" "spoke_b_to_spoke_a" {
      route_table_id         = aws_route_table.this["spoke_b"].id   # count guard removed
      destination_cidr_block = var.spoke_a_cidr
      transit_gateway_id     = aws_ec2_transit_gateway.hub.id
    }
    ```

14. **Apply** without the `-var scenario` flag (with both guards gone, the resources exist regardless, and omitting the flag returns `scenario` to healthy):

    ```bash
    terraform plan        # confirm: 2 to add (the ingress rule + the route), 0 to destroy
    terraform apply
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

    Read the plan: Terraform should report **2 to add** - the ingress rule and the route.

15. **Type** `yes` to apply.

> **Expected Result:** `Apply complete! Resources: 2 added.` You restored both faults in a single minimal change - exactly what you would hand to a change-review board: two resources, two layers, no collateral edits.

---

## Task 7: Re-Verify End to End

16. **Re-test** spoke A to spoke B directly:

    ```bash
    aws ssm start-session --target "$A_ID" --region "$REGION"
    ```

    Then, **inside the session**, ping spoke B and exit (paste separately - the session is a new shell):

    ```bash
    ping -c 3 -W 2 <B_IP>
    exit
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

> **Expected Result:** Replies, 0% packet loss. Both the inbound SG admit and the return route are in place, so the round trip completes.

17. **Run** the full health check:

    ```bash
    ./verify.sh
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

> **Expected Result:** `ALL CHECKS PASSED -- healthy baseline confirmed.` Check 4 (`spoke_a -> spoke_b reachable over the TGW`) passes. If it still fails, you fixed only one fault - go back and confirm *both* the `security_groups.tf` rule and the `network.tf` route had their `count` guard removed.

---

## Knowledge Checks

**Question 1.** Flow Logs showed a `REJECT` for ICMP at spoke B's ENI, and Reachability Analyzer reported "no route to destination" on the `spoke_b -> spoke_a` path. Why did it take *two different tools* to find the two faults - why didn't Flow Logs reveal the missing route?

<details><summary>Answer</summary>

Flow Logs record what actually happened to packets at an ENI: the inbound ICMP from spoke A reached spoke B's interface and was dropped by the security group, logged as `REJECT`. That is real, observed traffic - but the packet never got far enough to expose the *return*-path problem, because there was no reply traffic to log a route failure for (and a missing route does not generate a flow-log `REJECT` at all - it simply has nowhere to send the packet). Reachability Analyzer is static configuration analysis: it evaluates route tables and security groups along a path you specify and reports the first blocking resource, so asking it about `spoke_b -> spoke_a` surfaced the missing route directly. Observed-traffic tools and config-analysis tools see different layers; a compound fault often needs both.
</details>

**Question 2.** You did the entire investigation from the read-only `network-operations` role but performed the fix from your own identity. Why is that separation the correct operating model, and what would have happened if you had tried `terraform apply` while the role's temporary credentials were still exported?

<details><summary>Answer</summary>

Separating read-only diagnosis from change is least privilege in practice: an on-call engineer can see everything needed to find root cause without holding the power to change production, which limits blast radius and satisfies audit/change-control. The `network-operations` role grants `ec2:Describe*`, log reads, and the Reachability Analyzer actions - but not the write actions (`ec2:CreateRoute`, `ec2:AuthorizeSecurityGroupIngress`, etc.) that `terraform apply` needs. If you had left the role's credentials exported, the apply would have failed with `AccessDenied` / `UnauthorizedOperation`. Unsetting the temporary credentials returns you to your own identity, which holds the change permission - and the change goes through Terraform so it is reviewable and reproducible.
</details>

**Question 3.** A colleague says "I added the security-group rule, the Flow Log `REJECT` stopped, so the incident is resolved." Reachability Analyzer still reports the path as not reachable. Explain why both observations can be true at the same time, and what it tells you about closing incidents on a single signal.

<details><summary>Answer</summary>

Adding the SG ingress rule fixes Fault 1, so inbound ICMP is now admitted at spoke B's ENI and the `REJECT` disappears from Flow Logs - that signal genuinely cleared. But Fault 2, the missing return route in spoke B's route table, is untouched: spoke B can receive the ping but has no route to send the reply back to spoke A's CIDR, so the round trip still fails and Reachability Analyzer (which checks the `spoke_b -> spoke_a` configuration) still reports no route. Both are true because they describe different halves of the path. The lesson: a single cleared signal is not proof the incident is resolved. Confirm end-to-end reachability (and, ideally, a clean static analysis of both directions) before closing.
</details>

---

## Methodical Troubleshooting Recap

The capstone habit, in five steps you can reuse on any AWS network incident:

1. **Reproduce** the symptom precisely (here: `ping` spoke A to spoke B, 100% loss) so you can tell when it is truly fixed.
2. **Investigate read-only** from a least-privilege visibility role - find root cause without the power to change anything.
3. **Use observed-traffic and config-analysis tools together.** Flow Logs tell you what *happened* (a `REJECT` and where); Reachability Analyzer tells you what *can* happen (and names the blocking resource). Neither alone sees the whole picture.
4. **Assume compound until proven simple.** Do not stop at the first fault. Confirm every cause before you touch anything - fixing half a compound fault wastes a change window and erodes trust in the diagnosis.
5. **Remediate in the source of truth** (Terraform), as a minimal, reviewable change, then **re-verify end to end** (`./verify.sh`), not just the one signal you first chased.

In SYF's Aviatrix-managed environment the same discipline applies - the Controller programs the routes and segmentation, but the failure modes (a missing route, a too-tight policy) and the diagnostic tools (Flow Logs, Reachability Analyzer, the network-operations role) are identical.

---

## Lab Summary

You diagnosed a compound, two-fault connectivity failure entirely from a read-only `network-operations` role: VPC Flow Logs exposed a security-group `REJECT` at spoke B's ENI, and Reachability Analyzer proved a missing return route in spoke B's route table. You fixed both in Terraform as a single minimal change and confirmed full reachability with `./verify.sh`. Most importantly, you practiced the habit that separates a senior network engineer from a junior one: never close an incident on the first fault you find.

This completes the IO-106 lab track. You have deployed an AWS-native hub-and-spoke network with Terraform, exercised transit routing and segmentation, cross-account role assumption, private endpoints and DNS, and end-to-end troubleshooting - the AWS substrate that SYF's Aviatrix overlay and central endpoint account ride on.

---

## Resources

- [VPC Flow Logs - Flow log record syntax](https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html)
- [VPC Reachability Analyzer - Getting started](https://docs.aws.amazon.com/vpc/latest/reachability/getting-started.html)
- [VPC Reachability Analyzer - Explanation codes](https://docs.aws.amazon.com/vpc/latest/reachability/explanation-codes.html)
- [IAM - Using temporary security credentials (AssumeRole)](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_use-resources.html)
- [Amazon CloudWatch Logs - filter-log-events](https://docs.aws.amazon.com/cli/latest/reference/logs/filter-log-events.html)
- [Terraform - The `count` meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
