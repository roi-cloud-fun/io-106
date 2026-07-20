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

> **Where you run everything in this lab.** All `terraform`, `verify.sh`, `aws sts`, `aws iam`, and `aws cloudtrail` commands run on your **deploy box** (`io106-<your_id>-deploy`), from the Terraform module directory `~/io-106/lab_environment/lab_env_student`. This lab leans heavily on shell variables (`$NETOPS_ARN`, `$A_ID`, `$B_ID`, and the exported `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` assumed-role credentials) - **none of which survive an SSM timeout.** If your session drops mid-lab, reconnect (**Systems Manager > Session Manager > Start session** on `io106-<your_id>-deploy`), then `cd` back and **re-run the capture block in step 1** (and re-assume the role) before continuing:
>
> ```bash
> cd ~/io-106/lab_environment/lab_env_student
> ```

Before you break it, see the role doing real work so the failure is unmistakable.

1. **From the module directory**, confirm the healthy baseline and capture what you need:

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    bash ./verify.sh                                              # expect ALL CHECKS PASSED
    NETOPS_ARN=$(terraform output -raw network_operations_role_arn)
    ROLE_NAME=$(basename "$NETOPS_ARN")
    A_ID=$(terraform output -raw spoke_a_instance_id)
    B_ID=$(terraform output -raw spoke_b_instance_id)
    ```
<!-- source: course_outline_v3.md §"Lab 2" -->

2. **Assume** the network-operations role and run a real diagnostic under it: create a Reachability Analyzer path between your two spoke instances. Export the temporary credentials into your shell first:

    ```bash
    CREDS=$(aws sts assume-role --role-arn "$NETOPS_ARN" --role-session-name netops \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
    export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

    aws ec2 describe-route-tables --query 'length(RouteTables)'                       # READ: works
    PID=$(aws ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" \
      --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text) # Reachability Analyzer: works
    echo "created $PID"
    aws ec2 delete-network-insights-path --network-insights-path-id "$PID"             # tidy up
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN                     # back to your identity
    ```
<!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

**Expected Result:** The `assume-role` returns temporary `ASIA...` credentials. Under them, both the `describe` and the `create-network-insights-path` succeed - the role can list the network *and* run Reachability Analyzer. (Reachability Analyzer paths only accept `tcp` or `udp`, not `icmp`.) Remember to `unset` the variables so your shell returns to your own identity.

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

4. **Assume** the role again and try the same two calls as in Task 1:

    ```bash
    CREDS=$(aws sts assume-role --role-arn "$NETOPS_ARN" --role-session-name netops \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
    export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

    aws ec2 describe-route-tables --query 'length(RouteTables)'                        # still works
    aws ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" --protocol tcp  # now DENIED
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    ```
<!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

**Expected Result:** The assume-role *still succeeds* and the `describe` *still works* - but `create-network-insights-path` now fails with:

```
An error occurred (UnauthorizedOperation) when calling the CreateNetworkInsightsPath
operation: You are not authorized to perform this operation.
```

This is the confusing part, and it is the whole point: you can assume the role, basic reads work, but one specific action is refused. Your identity did not change. The role's permissions policy did not change. So the refusal is coming from *somewhere else above the role*.

---

## Task 4: Diagnose with CloudTrail

CloudTrail records the failed call with the caller, the action, and the error - the "who/what/when" you would attach to a ticket.

5. **Find the failed call.** In the console you can use **CloudTrail > Event history** (filter Event name = `CreateNetworkInsightsPath`). From the CLI, do not spam the screen with raw events - they are huge JSON blobs. Write them to a file, then extract just the fields that matter (run under your own identity, after the `unset` in Task 3):

    ```bash
    aws cloudtrail lookup-events \
      --lookup-attributes AttributeKey=EventName,AttributeValue=CreateNetworkInsightsPath \
      --max-results 10 --output json > events.json

    # one readable line per matching event (jq is pre-installed on the deploy box):
    jq -r '.Events[] | (.CloudTrailEvent|fromjson) | "\(.eventTime)  errorCode=\(.errorCode // "-")  caller=\(.userIdentity.arn // "-")"' events.json
    ```

    You should see two `CreateNetworkInsightsPath` lines: the **successful** create from Task 1 (`errorCode=-`) and the **denied** one from Task 3 (`errorCode=Client.UnauthorizedOperation`, or `AccessDenied`). No `jq`? Find the denial without scrolling: `grep -o '"errorCode":"[^"]*"' events.json`.
<!-- source: facts_extracted_v2.md §"CloudTrail for Access Troubleshooting" -->

6. **Read the denied event.** Confirm the denied line's `errorCode` is `Client.UnauthorizedOperation` / `AccessDenied`. For its full context, open `events.json` or run `jq '.Events[] | (.CloudTrailEvent|fromjson) | select(.errorCode)' events.json`: note the `userIdentity` is your assumed `netops` session and `eventName` is `CreateNetworkInsightsPath`.

**Expected Result:** You find a `CreateNetworkInsightsPath` event with an authorization-failure `errorCode`, made by your assumed network-operations session. CloudTrail confirms the *what* and *who*. It does not, by itself, explain *why* a role whose policy allows the action was refused - for that you compare the role's policy against its guardrail next. (CloudTrail Event history can lag a few minutes; if it is not visible yet, proceed and check back.)

---

## Task 5: Prove the Policy Allows It - Then Find the Guardrail

This is the core skill: when an action is denied but you believe it should be allowed, confirm the identity policy grants it, *then* look for a boundary or SCP above it.

7. **Show that the role's own policy grants the action.** Read its inline permissions policy and look for the Reachability Analyzer statement:

    ```bash
    ROLE_NAME=$(basename "$(terraform output -raw network_operations_role_arn)")   # set in Task 1; re-derive here in case you reconnected
    aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name network-visibility \
      --query 'PolicyDocument.Statement[?Sid==`ReachabilityAnalyzer`].Action'
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
    BARN=$(aws iam get-role --role-name "$ROLE_NAME" \
      --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)
    VID=$(aws iam get-policy --policy-arn "$BARN" --query 'Policy.DefaultVersionId' --output text)
    aws iam get-policy-version --policy-arn "$BARN" --version-id "$VID" \
      --query 'PolicyVersion.Document.Statement[].Action'
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

> **Note:** `terraform apply -var scenario=healthy` is the quick reset and also detaches the boundary. Editing the attachment is the realistic repair - you corrected the role so its policy is no longer capped.

> **Do not over-fix.** The temptation is to "make it work" by widening the boundary to `"Action": "*"` or deleting it entirely without thinking. A permissions boundary (like an SCP) is a deliberate guardrail - the right fix is to allow the *specific* actions the role legitimately needs, not to remove the ceiling wholesale. Here the boundary should simply not have applied to this role at all; in production you would instead get the role's OU or the SCP adjusted through change control.

**Expected Result:** Apply completes. `get-role` now shows no permissions boundary, and the role's effective permissions equal its policy again.

---

## Task 7: Re-Verify

13. **Assume** the role and re-run Reachability Analyzer - it should work again:

    ```bash
    CREDS=$(aws sts assume-role --role-arn "$NETOPS_ARN" --role-session-name netops \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
    export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

    PID=$(aws ec2 create-network-insights-path --source "$A_ID" --destination "$B_ID" \
      --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)
    echo "Reachability Analyzer works again: $PID"
    aws ec2 delete-network-insights-path --network-insights-path-id "$PID"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    ```
<!-- source: facts_extracted_v2.md §"VPC Reachability Analyzer" -->

**Expected Result:** `create-network-insights-path` now returns a `nip-...` id instead of `UnauthorizedOperation`. The cap is gone; the role's policy is back in full effect. Remember to `unset` the assumed credentials.

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
