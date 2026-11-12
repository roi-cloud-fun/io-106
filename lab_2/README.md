# Lab 2: Cross-Account Access and Permission Guardrails

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 3 - Federation and Cross-Account Access |
| **Duration** | 40 minutes |
| **Difficulty** | Advanced |
| **Prerequisites** | Lab 0 completed; stack deployed and healthy. Familiarity with IAM roles, `sts:AssumeRole`, identity vs. resource policies. |
| **Builds On** | Lab 0. Same per-student stack; this lab injects a permissions-boundary fault onto the `network-operations` role and you repair it. |

---

## Lab Overview

SYF's engineers do not hold long-lived AWS keys. They sign in through Microsoft Entra ID, federate into AWS, and then **assume a scoped IAM role** in the target account. A central example is the **network-operations role** - a read-only "see everything, change nothing" role that grants network visibility across accounts.

You can assume the role just fine. The trap in this lab is subtler and far more common in a large org: you assume the role successfully, you run basic `describe` calls successfully, but the moment you reach for a specific diagnostic tool - **Reachability Analyzer** - you get `AccessDenied`. The role's own permissions policy plainly lists that action. So why are you denied?

Because a role's *effective* permissions are not just what its policy grants - they are **what its policy grants AND what every guardrail above it allows**. Here that guardrail is a **permissions boundary**: a ceiling attached to the role that caps it below its own policy. `scenario=lab2` attaches a boundary that omits the Reachability Analyzer actions, so they are denied even though the role policy allows them.

In SYF's real multi-account organization, this same "ceiling above your role" is usually a **Service Control Policy (SCP)** applied at the Organization or OU level. A single training account cannot create SCPs (they require the Organizations management account), so we model the identical behavior with a permissions boundary. The troubleshooting method - *prove the policy allows it, then find the guardrail that doesn't* - is exactly the same.
<!-- source: facts_extracted_v2.md §"Service Control Policies" -->



---

## Scenario

A teammate on the network team reports that they can sign in, assume the network-operations role, and list resources, but when they try to run **Reachability Analyzer** to trace a broken path they get `AccessDenied` - `not authorized to perform: ec2:CreateNetworkInsightsPath`. They are confused: the role is *supposed* to allow that, and they can see the permission in the role's policy. Nobody changed the role's permissions policy. You own the role. Your job is to find the failed call in CloudTrail, prove the role policy really does grant the action, then discover the guardrail that is overriding it - and repair it as code without tearing the guardrail down entirely.

---

## Learning Objectives

By the end of this lab, you will:

- Assume a scoped role and run a privileged diagnostic action (Reachability Analyzer) under its temporary credentials.
- Inject a permissions-boundary fault with `terraform apply -var scenario=lab2` and reproduce the `AccessDenied`.
- Use **CloudTrail** to locate the failed `CreateNetworkInsightsPath` event and read its `errorCode`.
- Reason about **effective permissions = identity policy AND permissions boundary**, and recognize this as the single-account stand-in for an **SCP** guardrail.
- Read a role's attached **permissions boundary**, identify the action it omits, and repair the role in Terraform.

---

## Task 1: Exercise the Healthy Pattern First

> **Where you run everything in this lab.** All `terraform`, `verify.sh`, `aws sts`, `aws iam`, and `aws cloudtrail` commands run on your **deploy box** (`io106-<your_id>-deploy`), from the Terraform module directory `~/io-106/lab_environment/lab_env_student`. This lab uses shell variables (`$REGION`, `$NETOPS_ARN`, `$A_ID`, `$B_ID`) that do **not** survive an SSM timeout. If your session drops mid-lab, reconnect (**Systems Manager > Session Manager > Start session** on `io106-<your_id>-deploy`), then re-run the capture block in step 1. The `netops` profile you create in step 2 is written to `~/.aws/config` on disk, so that part *does* survive a reconnect - you do not have to re-assume the role:
>
> ```bash
> cd ~/io-106/lab_environment/lab_env_student
> ```

Before you break it, see the role doing real work so the failure is unmistakable.

1. **Confirm the healthy baseline and capture what you need.** Your deploy box logs you straight into the module directory, so there is nothing to `cd` into unless you wandered off (the note above has the path if you need it):

    ```bash
    bash ./verify.sh
    REGION=$(terraform output -raw region)
    NETOPS_ARN=$(terraform output -raw network_operations_role_arn)
    ROLE_NAME=$(basename "$NETOPS_ARN")
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    Then check which scenario your stack is currently in:

    ```bash
    terraform output -raw scenario
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

> [!IMPORTANT]
> **This task only works if the lab2 fault is NOT already applied.** Task 1 is the "before" picture - it shows Reachability Analyzer *succeeding* under the role, so that the denial in Task 3 is unmistakable.
>
> If the command above printed **`lab2`**, the boundary is already attached and step 2's Reachability Analyzer call will fail with `UnauthorizedOperation` instead of succeeding. Reset to healthy first, then come back:
>
> ```bash
> terraform apply -var scenario=healthy
> ```
>
> Anything else (`healthy`, or `lab1` after you repaired it in Lab 1) is fine - the boundary is only attached under `lab2`.

2. **Assume** the network-operations role and run a real diagnostic under it: create a Reachability Analyzer path between your two spoke instances.

    First, see the mechanics directly. `sts assume-role` returns a **temporary** credential set - an `ASIA...` access key, a secret, and a session token - which expire (an hour here, set by the role's `max_session_duration`). These are *not* long-lived keys, and you hold no stored secret anywhere: the `assume-role` call itself is authenticated by your deploy box's own instance role.

    ```bash
    aws sts assume-role --role-arn "$NETOPS_ARN" --role-session-name netops --query 'Credentials.{Key:AccessKeyId,Expires:Expiration}' --output table
    ```
    <!-- source: https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html -->

    Note the `ASIA` prefix (temporary) rather than `AKIA` (long-lived IAM user key), and the expiry timestamp. That is the whole point of role assumption: credentials that are scoped, attributable to a session name, and self-expiring.

    Now configure the role as a **named profile** and use that for the rest of the lab. This is how a jump box is really set up, and it avoids exporting credentials into your shell at all:

    ```bash
    mkdir -p ~/.aws
    { echo "[profile netops]"; echo "role_arn = $NETOPS_ARN"; echo "credential_source = Ec2InstanceMetadata"; echo "region = $REGION"; } > ~/.aws/config
    cat ~/.aws/config
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html -->

    That prints the file back so you can see the role ARN and region were substituted. Writing the file with `>` rather than appending means re-running it is safe - you cannot end up with the profile defined twice. (Your deploy box has no other AWS profiles, so there is nothing to overwrite.)

    Now confirm which identity that profile gives you:

    ```bash
    aws --profile netops sts get-caller-identity --query Arn --output text
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html -->

    `credential_source = Ec2InstanceMetadata` tells the CLI to authenticate with the instance role and then assume `role_arn` for you - refreshing the temporary credentials automatically as they expire. Expect the ARN to come back as `assumed-role/io106-<your_id>-network-operations/botocore-session-...`.

    Now prove the role can **read** the network. Ask it for your own two spoke instances:

    ```bash
    aws --profile netops ec2 describe-instances --region "$REGION" --instance-ids "$A_ID" "$B_ID" --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output table
    ```
    <!-- source: facts_extracted_v2.md §"Cross-Account IAM Roles" -->

    You should get back your two instance ids with their `10.106.1.x` and `10.106.2.x` private IPs - values you recognise from Lab 0's outputs. That is the "see everything" half of the role working: it answered a question about your network without you holding any permission of your own.

    ```bash
    aws --profile netops ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
    ```
    <!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

    Both succeed - the role can list the network **and** run Reachability Analyzer.

    > **Why the profile, not `export AWS_ACCESS_KEY_ID=...`?** Exported credentials
    > are invisible state. They do not survive an SSM reconnect, so a dropped
    > session silently returns you to your own identity mid-investigation; and if
    > you forget to `unset` them, the next `terraform apply` runs as a read-only
    > role and fails with a wall of `AccessDenied` (Lab 4 has a callout for exactly
    > that). `--profile netops` is explicit on every command: you can always see
    > which identity a command used by reading the command itself, and there is
    > nothing to unset.
    <!-- source: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html -->

**Expected Result:** `assume-role` shows an `ASIA...` key with an expiry, and `--profile netops` reports the `assumed-role/io106-<your_id>-network-operations/...` ARN. Under that profile both the `describe` and the `create-network-insights-path` succeed - the role can list the network *and* run Reachability Analyzer. (Reachability Analyzer paths only accept `tcp` or `udp`, not `icmp`.) Because nothing was exported, your own identity is still what any command *without* `--profile netops` uses - there is nothing to unset.

> **If `assume-role` itself returns `AccessDenied`:** your deploy box's own instance role is missing `sts:AssumeRole` on the network-operations role. That is a deploy-box setup issue, not part of the lab - raise it with your instructor before continuing.

---

## Task 2: Inject the Fault

3. **Preview, then apply** the lab2 scenario from the module directory. Always run `plan` before `apply` - it shows what will change and catches errors before they reach the account. This attaches a **permissions boundary** to the network-operations role - it does not touch the role's own permissions policy:

    ```bash
    terraform plan -var scenario=lab2     # review the change before applying
    terraform apply -var scenario=lab2
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    Read the plan. It creates `aws_iam_policy.netops_boundary` (if not already present) and updates `aws_iam_role.network_operations` to set its `permissions_boundary`. The role's `network-visibility` policy is unchanged. Type `yes`.

**Expected Result:** Apply completes. The only meaningful change is that the network-operations role now has a permissions boundary attached. Its permissions policy - and every network resource - is untouched.

---

## Task 3: Reproduce the Symptom

4. **Run the same two calls as in Task 1**, under the same `netops` profile. Re-derive the ids first in case you reconnected:

    ```bash
    REGION=$(terraform output -raw region)
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    echo "region=$REGION A=$A_ID B=$B_ID"
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    The read still works:

    ```bash
    aws --profile netops ec2 describe-route-tables --query 'length(RouteTables)' --output text
    ```
    <!-- source: facts_extracted_v2.md §"Cross-Account IAM Roles" -->

    Reachability Analyzer is now refused:

    ```bash
    aws --profile netops ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" --protocol tcp
    ```
    <!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

    Note what did **not** happen: the role assumption itself still succeeded. The profile resolved, the identity is still the `network-operations` role, and a read-only call still returns data. Only this one action is blocked - which is exactly why the failure is confusing in the field and why the next task goes looking for a guardrail rather than a broken role.

**Expected Result:** The assume-role *still succeeds* and the `describe` *still works* - but `create-network-insights-path` now fails with:

```
An error occurred (UnauthorizedOperation) when calling the CreateNetworkInsightsPath
operation: You are not authorized to perform this operation.
```

This is the confusing part, and it is the whole point: you can assume the role, basic reads work, but one specific action is refused. Your identity did not change. The role's permissions policy did not change. So the refusal is coming from *somewhere else above the role*.

---

## Task 4: Diagnose with CloudTrail

CloudTrail records the failed call with the caller, the action, and the error - the "who/what/when" you would attach to a ticket.

5. **Find the failed call** (run under your own identity, after the `unset` in Task 3).

    **Console path:** Open **CloudTrail > Event history**, set the lookup filter to **Event name = `CreateNetworkInsightsPath`** (narrow the time range to the last hour if needed), and click the matching event. On the event detail page, read the **Error code** (`Client.UnauthorizedOperation` / `AccessDenied`) and expand **Event record** (the JSON) to see the denied action and the `userIdentity` of your assumed `netops` session.

    **CLI path:** The raw events are huge JSON blobs, so do not dump them to the screen - write them to a file, then extract just the fields that matter:

    ```bash
    aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateNetworkInsightsPath --max-results 10 --output json > events.json
    echo "events written: $(wc -l < events.json) lines"
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/cloudtrail/ -->

    Then pull out one readable line per event (`jq` is pre-installed on the deploy box):

    ```bash
    jq -r '.Events[] | (.CloudTrailEvent|fromjson) | "\(.eventTime)  errorCode=\(.errorCode // "-")  caller=\(.userIdentity.arn // "-")"' events.json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/cloudtrail/ -->

    You should see two `CreateNetworkInsightsPath` lines: the **successful** create from Task 1 (`errorCode=-`) and the **denied** one from Task 3 (`errorCode=Client.UnauthorizedOperation`, or `AccessDenied`). No `jq`? Find the denial without scrolling: `grep -o 'errorCode[^,]*' events.json`.

    > **If the denied call is not there yet, you have not done anything wrong.** CloudTrail management events typically take **5-15 minutes** to become searchable in Event history. If you only see the successful create from Task 1, wait a few minutes and re-run the `lookup-events` command - the denial will appear.
<!-- source: facts_extracted_v2.md §"CloudTrail for Access Troubleshooting" -->

6. **Read the denied event.** Confirm the denied line's `errorCode` is `Client.UnauthorizedOperation` / `AccessDenied`. For its full context, open `events.json` or run `jq '.Events[] | (.CloudTrailEvent|fromjson) | select(.errorCode)' events.json`: note the `userIdentity` is your assumed `netops` session and `eventName` is `CreateNetworkInsightsPath`.

**Expected Result:** You find a `CreateNetworkInsightsPath` event with an authorization-failure `errorCode`, made by your assumed network-operations session. CloudTrail confirms the *what* and *who*. It does not, by itself, explain *why* a role whose policy allows the action was refused - for that you compare the role's policy against its guardrail next. (CloudTrail Event history can lag a few minutes; if it is not visible yet, proceed and check back.)

---

## Task 5: Prove the Policy Allows It - Then Find the Guardrail

This is the core skill: when an action is denied but you believe it should be allowed, confirm the identity policy grants it, *then* look for a boundary or SCP above it.

7. **Show that the role's own policy grants the action.** Read its inline permissions policy and look for the Reachability Analyzer statement:

    ```bash
    ROLE_NAME=$(basename "$(terraform output -raw network_operations_role_arn)")
    echo "role=$ROLE_NAME"
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    ```bash
    aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name network-visibility --query 'PolicyDocument.Statement[?Sid==`ReachabilityAnalyzer`].Action'
    ```
    <!-- source: facts_extracted_v2.md §"Cross-Account IAM Roles" -->

    You will see `ec2:CreateNetworkInsightsPath` (and the other network-insights actions) listed and `Allow`ed. So the identity policy is **not** the problem.

8. **Find the guardrail.** Check whether the role has a permissions boundary attached:

    ```bash
    aws iam get-role --role-name "$ROLE_NAME" --query 'Role.PermissionsBoundary'
    ```
    <!-- source: facts_extracted_v2.md §"Service Control Policies" -->

9. **Read the boundary's contents** - the document that defines the ceiling:

    ```bash
    BARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)
    echo "boundary=$BARN"
    ```
    <!-- source: facts_extracted_v2.md §"Service Control Policies" -->

    ```bash
    VID=$(aws iam get-policy --policy-arn "$BARN" --query 'Policy.DefaultVersionId' --output text)
    echo "version=$VID"
    ```
    <!-- source: facts_extracted_v2.md §"Service Control Policies" -->

    ```bash
    aws iam get-policy-version --policy-arn "$BARN" --version-id "$VID" --query 'PolicyVersion.Document.Statement[].Action'
    ```
    <!-- source: facts_extracted_v2.md §"Service Control Policies" -->

**Expected Result:** `get-role` shows a `PermissionsBoundary` is attached (its ARN ends `-netops-boundary`). Reading the boundary, its allowed actions include `ec2:Describe*`, `ec2:SearchTransitGatewayRoutes`, logs, Route 53, and so on - **but none of the `ec2:*NetworkInsights*` actions**. A role's effective permissions are the **intersection** of its identity policy and its boundary. Reachability Analyzer is in the policy but not in the boundary, so it is capped out. Diagnosis complete: the denial is the permissions boundary, not the role policy. *(In SYF's production org, you would run the same comparison against the OU's SCP instead of a boundary.)*

---

## Task 6: Fix It in Terraform

The boundary is attached in `iam.tf` by a conditional the lab2 scenario turns on:

```hcl
permissions_boundary = local.is_lab2 ? aws_iam_policy.netops_boundary.arn : null
```
<!-- source: facts_extracted_v2.md §"Service Control Policies" -->

10. **In the module directory, edit** `iam.tf`. Detach the boundary from the role by setting it to `null` regardless of scenario:

    ```hcl
    permissions_boundary = null
    ```

11. **Preview** the fix with lab2 still active - this proves you removed the cap, not just flipped the toggle:

    ```bash
    terraform plan -var scenario=lab2
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    The plan shows an in-place update to `aws_iam_role.network_operations` removing its `permissions_boundary`, even though `scenario=lab2`.

12. **Apply** the fix:

    ```bash
    terraform apply -var scenario=lab2
    ```
    <!-- source: course_outline_v3.md §"Lab 2" -->

    Terraform prints the plan again and waits for confirmation - type `yes`
    and press **Enter**. It will not proceed until you do; nothing has changed
    in AWS until you answer.

> **Note:** `terraform apply -var scenario=healthy` is the quick reset and also detaches the boundary. Editing the attachment is the realistic repair - you corrected the role so its policy is no longer capped.

> **Do not over-fix.** The temptation is to "make it work" by widening the boundary to `"Action": "*"` or deleting it entirely without thinking. A permissions boundary (like an SCP) is a deliberate guardrail - the right fix is to allow the *specific* actions the role legitimately needs, not to remove the ceiling wholesale. Here the boundary should simply not have applied to this role at all; in production you would instead get the role's OU or the SCP adjusted through change control.

**Expected Result:** Apply completes. `get-role` now shows no permissions boundary, and the role's effective permissions equal its policy again.

---

## Task 7: Re-Verify

13. **Re-run Reachability Analyzer under the role** - it should work again:

    ```bash
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    aws --profile netops ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
    ```
    <!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

**Expected Result:** `create-network-insights-path` now returns a `nip-...` id instead of `UnauthorizedOperation`. The cap is gone; the role's policy is back in full effect.

---

## How This Maps to SYF's Real Model

| In this single-account lab | In SYF's real environment |
|---|---|
| The guardrail above the role is a **permissions boundary** | The guardrail is typically a **Service Control Policy (SCP)** on the account's **Organization/OU** |
| You read the boundary with `iam get-role` / `get-policy-version` | You read the SCP in the **Organizations** console (or request it from the platform team) |
| You detach the boundary in Terraform | The SCP change is requested and approved through **ServiceNow**, governed by the **SIAM** process |
| Effective permission = identity policy AND boundary | Effective permission = identity policy AND **every** SCP on the path AND any boundary |

The troubleshooting method is identical regardless of which guardrail is in play: confirm the identity policy grants the action, then walk *up* - permissions boundary, then SCPs - until you find the layer that does not. A single training account cannot host an Organization, so the permissions boundary stands in for the SCP; the reasoning transfers exactly.

---

## Knowledge Check

**Question 1:** You assumed the role successfully and `ec2:DescribeRouteTables` worked, but `ec2:CreateNetworkInsightsPath` was denied - and the role's permissions policy clearly grants `ec2:CreateNetworkInsightsPath`. What does that combination tell you about where the denial comes from, before you look at anything else?

<details><summary>Answer</summary>

> **Answer:** If you could assume the role, the trust policy is fine. If a `describe` worked, your credentials and the role's basic policy are fine. So a denial on one specific action that the role's policy *does* grant cannot be coming from the identity policy - it must come from a layer that further restricts the role: a **permissions boundary** (or, in an org, an **SCP**). Effective permissions are the *intersection* of the identity policy and every guardrail above it, so an action must be allowed in *all* layers to succeed.
</details>

**Question 2:** A colleague "fixes" the AccessDenied by editing the boundary to `"Action": "*"`. Why is that the wrong remediation, and what is the correct one?

<details><summary>Answer</summary>
    
> **Answer:** `"Action": "*"` removes the ceiling entirely - the boundary (or SCP) exists on purpose to cap what the role can ever do, and blowing it open defeats that control for every action, not just the one you needed. The correct fix is to make the role no longer subject to a boundary that does not belong on it (detach it), or to allow the *specific* legitimate actions in the guardrail. You restore the intended control surface; you do not delete it.
</details>

**Question 3:** In SYF's real multi-account organization, you hit the same symptom - an action allowed by a role's policy is denied. You confirm there is no permissions boundary on the role. Where do you look next, and why is the method the same as in this lab?

<details><summary>Answer</summary>
    
> **Answer:** You look at the **SCPs** applied to the account's Organization/OU. SCPs are a guardrail above every role in the account, exactly like a permissions boundary is a guardrail on a single role - effective permission is still the intersection of the identity policy and every guardrail. The method is unchanged: prove the identity policy allows the action, then walk up the guardrail layers until you find the one that does not. The permissions boundary in this lab is the single-account stand-in for that SCP layer.
</details>
---

## Summary

You assumed the network-operations role and ran Reachability Analyzer successfully, then injected a permissions-boundary fault that left the role assumable and its policy intact yet silently capped one privileged action. You traced the denial through CloudTrail, proved the role's policy granted the action, found the permissions boundary that overrode it, and detached it as code - without tearing the guardrail open. You saw that effective permissions are the intersection of a role's policy and every guardrail above it, and how a permissions boundary here stands in for an SCP in SYF's real Organizations-governed environment.

## Completion Checklist

- [ ] Assumed the role and ran Reachability Analyzer successfully on the healthy baseline
- [ ] `scenario=lab2` applied; `UnauthorizedOperation` reproduced on `CreateNetworkInsightsPath` while `describe` still worked
- [ ] Failed `CreateNetworkInsightsPath` event found in CloudTrail
- [ ] Confirmed the role's `network-visibility` policy grants the action
- [ ] Found the attached permissions boundary and confirmed it omits the network-insights actions
- [ ] `iam.tf` edited to detach the boundary and applied with `scenario=lab2`; Reachability Analyzer works again

## Next Steps

In **Lab 3: Private Connectivity - Endpoints and DNS**, you return to the data plane: a Route 53 private hosted zone that one spoke can no longer resolve. You will diagnose the NXDOMAIN, find the missing zone association, and repair it - the private DNS pattern behind SYF's centralized endpoint and Route 53 model.

---

## Resources

- [IAM permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- [Service Control Policies (SCPs)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [How IAM evaluates effective permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
- [VPC Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html)
- [CloudTrail Event history](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/view-cloudtrail-events.html)
- [STS AssumeRole API reference](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) - what the temporary credential set contains and how long it lasts
- [Use an IAM role in the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html) - `role_arn` + `credential_source` named profiles, the pattern used in Task 1
- [Temporary security credentials in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html) - why `ASIA...` credentials expire and why that is preferable to long-lived keys
