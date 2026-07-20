# IO-106 — Lab Operator IAM Permissions

`deploy_box_iam_policy.json` is the IAM policy that the **lab operator identity** needs to run every IO-106 lab (0–4) end to end. Attach it to:

- the **per-student deploy-box EC2 instance role** (`io106-<id>-deploy`) — this is the identity that runs `terraform`, `verify.sh`, and all the `aws` CLI commands in the labs; **and/or**
- the **student's federated console role**, if students also perform the console steps (Reachability Analyzer, CloudTrail Event history, CloudWatch Log Analytics, Route 53, VPC route tables) under their own sign-in.

It is a single superset policy: everything any lab identity touches. You can attach it to both places, or split it if you prefer.

## What each statement covers

| Sid | Why it's needed | Labs / steps |
|-----|-----------------|--------------|
| `NetworkingProvisionAndDiagnose` | `terraform apply/destroy` builds the whole stack (VPCs, subnets, route tables, routes, Transit Gateway + attachments, interface VPC endpoints, security groups, EC2 instances, flow logs) and the labs read it back; also **Reachability Analyzer** (`*NetworkInsights*`). | All labs; Lab 1/4 Reachability Analyzer |
| `CloudWatchLogsFlowLogsAndInsights` | Terraform creates the flow-log group; labs query it in **Log Analytics** (Logs Insights: `StartQuery`/`GetQueryResults`). | Lab 1/3/4 Flow Logs |
| `Route53PrivateDns` | Terraform creates the `lab.internal` private zone, record, and VPC associations; Lab 3 diagnoses/repairs the association. | Lab 0 build; Lab 3 |
| `SsmParamSessionAndRunCommand` | AL2023 AMI lookup (`GetParameter`); **Session Manager** shells (`StartSession`); `verify.sh` runs checks on instances via `SendCommand`/`GetCommandInvocation`; `DescribeInstanceInformation`. | Lab 0 connect; `verify.sh`; all `start-session` |
| `CloudTrailLookup` | `aws cloudtrail lookup-events` to find the denied call. | Lab 2 Task 4 |
| `StsIdentity` | `aws sts get-caller-identity` and the Terraform `aws_caller_identity` data source. | All |
| `AssumeLabRoles` | `aws sts assume-role` onto the `network-operations` / `app` roles. **Without this, Lab 2 fails at the first `assume-role`.** Scoped to `io106-*-network-operations` and `io106-*-app`. | Lab 2 |
| `ManageLabIamRoles` / `ManageLabIamPolicies` | Terraform creates/updates/destroys the lab roles, inline policies, instance profile, and the **permissions boundary** (attach/detach = `PutRolePermissionsBoundary`/`DeleteRolePermissionsBoundary`). Scoped to `io106-*`. | Lab 0 build; Lab 2 fix |
| `PassLabServiceRoles` | `iam:PassRole` for the EC2 instance profile and the VPC flow-logs delivery role. Scoped to `io106-*` and limited to `ec2.amazonaws.com` + `vpc-flow-logs.amazonaws.com`. | Lab 0 build |
| `IamReadForDiagnostics` | `ListRoles`/`ListPolicies` for read-back (Lab 2 reads the role, its policy, and the boundary via `GetRole*`/`GetPolicy*`, which are covered under `ManageLabIam*` on `io106-*`). | Lab 2 |

## Scoping notes

- **IAM is scoped to `io106-*`** roles/policies/instance-profiles, and `PassRole` is limited to the two services that consume these roles — so this identity cannot touch IAM outside the lab namespace.
- **EC2 / Logs / Route 53 / SSM / CloudTrail** are granted on `*` (these services largely don't support tight resource-level scoping for the create/describe actions Terraform needs). To tighten, add a `Condition` on `aws:RequestedRegion` (the stack defaults to `us-east-1`).
- Assumes **local Terraform state** on the deploy box (no S3/DynamoDB backend). If you move state to a remote backend, add the backend's S3/DynamoDB permissions.

## What this policy does NOT cover

- The **permissions of the lab-created roles themselves** (`network-operations`, `app`, `instance`, `flow-logs`) — those are defined in `lab_env_student/iam.tf` and are created by Terraform, not by this policy.
- Anything outside the `io106-*` namespace.
