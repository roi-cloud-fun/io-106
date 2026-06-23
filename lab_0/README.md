# Lab 0: Deploy Your Network Lab

| | |
|---|---|
| **Course** | IO-106 AWS Network Architecture and Cross-Account Access |
| **Chapter** | Chapter 1 - SYF AWS Network Architecture |
| **Duration** | 30 minutes |
| **Difficulty** | Advanced |
| **Prerequisites** | Solid VPC, routing, and security-group fundamentals; basic AWS CLI v2; a training-account session. No prior Terraform experience required - this lab teaches what you need. |
| **Builds On** | None. Lab 0 is the foundation. It deploys the per-student network stack that Labs 1-4 break, diagnose, and repair. Do not tear it down between labs. |

---

## Lab Overview

Every later lab in this course starts from the same place: a healthy, AWS-native multi-VPC network that you own. In this lab you deploy that network with Terraform, learn just enough Terraform to read what you applied, and run an automated health check to confirm the baseline is green before any faults are injected.

The stack is deliberately small but architecturally complete. It mirrors the shape of SYF's production environment — a hub-and-spoke transit, a shared-endpoint pattern, private DNS, and a read-only cross-account access role — using native AWS primitives you can see and touch. Later labs flip a single switch (`-var scenario=labN`) to inject one realistic fault into one real resource; you then diagnose it with AWS-native tooling and fix it by editing this same Terraform.

What you deploy:

```
                 Transit / shared VPC (10.106.0.0/24)
                 |- STS interface endpoint   (central-endpoint-account pattern)
                 |- Route53 private zone      lab.internal
                            |
                   AWS Transit Gateway (hub)     <- Aviatrix-transit stand-in
                  +---------+---------+
         Spoke A VPC (10.106.1.0/24)   Spoke B VPC (10.106.2.0/24)
         |- SSM interface endpoints     |- SSM interface endpoints
         |- t3.micro test instance      |- t3.micro test instance

   VPC Flow Logs (all 3 VPCs) -> CloudWatch Logs
   IAM: network-operations (read-only, cross-account-style) + app role
   Security groups ONLY - no NACLs (matches SYF)
```

The whole stack is **fully private**: no internet gateway, no NAT. The test instances reach Systems Manager and AWS services through interface VPC endpoints (PrivateLink), and you access them through SSM Session Manager — no SSH, no key pairs, no public IPs.

---

## Scenario

You are a network engineer onboarding to SYF's AWS environment. Before you can troubleshoot it, you need a faithful, disposable copy you can experiment on without touching production. Terraform is how SYF provisions and reproduces network state, so your first task is to stand up your personal copy of the reference topology, confirm it is healthy, and learn to read the Terraform that defines it. Every diagnosis you perform for the rest of the day runs against this stack.

> **Aviatrix note (read this first — it frames the whole course):** This lab uses AWS Transit Gateway. In your environment the hub-and-spoke transit is **Aviatrix** (Aviatrix Transit Gateway / Spoke Gateways), managed by the network team - the concepts map directly; the management plane differs. You are building by hand what the Aviatrix Controller automates, which is exactly what makes each component visible and troubleshootable.

---

## Learning Objectives

By the end of this lab, you will:

- Deploy a multi-VPC AWS network stack (Transit Gateway hub-spoke, interface VPC endpoints, a Route53 private hosted zone, SSM-managed instances, security groups) with a single `terraform apply`.
- Read a Terraform configuration well enough to map every output back to a real resource and understand how the `scenario` variable will drive later labs.
- Run `verify.sh` and interpret its PASS/FAIL output to confirm a healthy baseline.
- Use SSM Session Manager to reach private instances with no SSH, no public IP, and no NAT.

---

## Task 1: Confirm Your Tooling

1. **Connect to your deploy instance** with SSM Session Manager — there is nothing to install on your own laptop. From the Console, open **Systems Manager**, then **Session Manager**, and **Start session** against `io106-<your_id>-deploy`. Or from any host with the AWS CLI: `aws ssm start-session --target <your-deploy-instance-id>`. Access is SSM-only 13 no SSH, no key pair, no public IP.

2. **Confirm** the three required tools are present:

    ```bash
    terraform version          # need >= 1.10
    aws --version              # need AWS CLI v2
    session-manager-plugin     # SSM Session Manager plugin
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

    These are pre-installed on the deploy instance. If any command is missing, tell your instructor before the connectivity checks in Task 6.

3. **Change directory** into the student lab module. The `io-106` repo is already cloned on the box:

    ```bash
    cd ~/io-106/lab_environment/lab_env_student
    ```

> **Note:** Run Terraform from the deploy instance's local checkout (`~/io-106`), where your `.tfstate` stays consistent. Do not copy the module onto a synced drive.

**Expected Result:** All three commands print a version or usage banner. You are in `~/io-106/lab_environment/lab_env_student`, which contains `network.tf`, `iam.tf`, `endpoints.tf`, and the other `.tf` files.

---

## Task 2: Initialize Terraform and Read What You Are About to Build

Terraform works in three moves: `init` downloads the providers, `plan` shows what it *would* change, and `apply` makes the change. You will use all three.

4. **Initialize** the working directory. This reads `versions.tf`, downloads the AWS provider, and creates the `.terraform/` directory:

    ```bash
    terraform init
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

5. **Skim** the configuration so the outputs in Task 5 mean something. Open these files and note what each declares:

    - `network.tf` - the three VPCs, their subnets, the Transit Gateway, and the VPC route tables that wire the spokes to the hub.
    - `endpoints.tf` - the SSM interface endpoints (per spoke), the shared STS endpoint in the transit VPC, and the `lab.internal` Route53 private hosted zone.
    - `security_groups.tf` - security groups only (no NACLs), with endpoint SGs referencing instance SGs by ID.
    - `iam.tf` - the `network-operations` read-only role and a narrower `app` role.
    - `variables.tf` - note the `scenario` variable. It defaults to `healthy`. Later labs pass `-var scenario=lab1` (and so on) to inject exactly one fault.

6. **Notice** the `scenario` mechanism while you are in `variables.tf` and `locals.tf`. A handful of resources carry a Terraform `count` guard such as `count = local.is_lab1 ? 0 : 1`. In the healthy baseline every guard evaluates to `1` (the resource exists). When a later lab sets `scenario=lab1`, one guard flips to `0` and that single resource disappears - that is the entire fault. You do not need to change anything now; just know where the switch lives.

**Expected Result:** `terraform init` ends with `Terraform has been successfully initialized!`. You can locate the `scenario` variable in `variables.tf` and at least one `count = local.is_labN ? 0 : 1` guard in `network.tf`.

---

## Task 3: Set Your Student ID

Every named resource is prefixed `io106-<student_id>-` so all eight students share one account without collisions. Your instructor assigns your ID (for example `s01`).

7. **Copy** the example tfvars file and set your ID:

    ```bash
    cp terraform.tfvars.example terraform.tfvars
    # edit terraform.tfvars: set student_id = "s01"  (use YOUR assigned id)
    ```

    `student_id` must be lowercase alphanumeric, 2-12 characters. Leave `scenario = "healthy"` for Lab 0.

**Expected Result:** `terraform.tfvars` contains your assigned `student_id` and `scenario = "healthy"`.

---

## Task 4: Preview the Plan, Then Apply

8. **Generate a plan** to preview exactly what Terraform will create before it touches the account:

    ```bash
    terraform plan
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

    Read the summary line at the bottom - something like `Plan: 60 to add, 0 to change, 0 to destroy`. A plan that only *adds* (nothing to change or destroy) is what you expect on a first deploy. Reading the plan before every apply is a core Terraform discipline: it is your change-preview gate.

9. **Apply** the configuration. Terraform prints the plan again and asks for confirmation; type `yes`:

    ```bash
    terraform apply
    ```
    <!-- source: facts_extracted_v2.md §"Transit Gateway" -->

    This takes roughly **5-8 minutes** — the Transit Gateway and its three attachments are the slow part.

**Expected Result:** `terraform apply` ends with `Apply complete! Resources: N added, 0 changed, 0 destroyed.` followed by an **Outputs:** block.

---

## Task 5: Read the Outputs and Map Them to the Architecture

The `outputs.tf` file exposes the handful of identifiers you (and the lab tooling) need. Reading them is how you connect Terraform state to real resources.

10. **List** all outputs:

    ```bash
    terraform output
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

11. **Pull individual values** with `-raw` (this is the form you will reuse constantly in later labs — it strips quotes so the value drops straight into a shell variable):

    ```bash
    terraform output -raw transit_gateway_id
    terraform output -raw spoke_a_instance_id
    terraform output -raw spoke_b_instance_private_ip
    terraform output -raw network_operations_role_arn
    terraform output -raw flow_log_group
    terraform output -raw lab_internal_zone_id
    ```
    <!-- source: facts_extracted_v2.md §"Transit Gateway" -->

12. **Map** each one back to the diagram: `transit_gateway_id` is the hub (your Aviatrix-transit stand-in); the two instance outputs are the connectivity probes you ping between in Lab 1; `network_operations_role_arn` is the read-only cross-account-style role you assume in Lab 2; `flow_log_group` is the CloudWatch Logs group where VPC Flow Logs land for Lab 4.

**Expected Result:** Each `terraform output -raw` command prints a single concrete value (a `tgw-...` ID, an `i-...` ID, a `10.106.2.x` IP, a `arn:aws:iam::...:role/io106-<id>-network-operations` ARN). Note the account ID inside that role ARN - you will need it in Lab 2.

---

## Task 6: Run the Health Check

The instances run the SSM agent and register with Systems Manager over the private interface endpoints. **Registration takes about 5-7 minutes after apply.** `verify.sh` checks every component and prints PASS/FAIL.

13. **Wait** about 5 minutes after the apply completed, then run the verifier:

    ```bash
    ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

14. **Read** the output. It checks, in order: both instances running; both instances Online in SSM (proves the private endpoints and endpoint SGs work); the Transit Gateway has all three attachments; spoke A can ping spoke B over the TGW; `app.lab.internal` resolves from spoke A via the Route53 private zone; Flow Logs are flowing; and the `network-operations` role exists.

    If the SSM checks FAIL on the first run, the instances simply have not finished registering. Wait 2-3 minutes and re-run `./verify.sh`. A `WARN` about no Flow Log streams yet is **not** a failure — first records take about 10 minutes to deliver.

**Expected Result:** `ALL CHECKS PASSED -- healthy baseline confirmed. You are ready for Lab 1.` If any check other than the Flow Logs WARN fails after a couple of retries, raise it with your instructor before continuing - Labs 1-4 assume a clean baseline.

---

## Task 7: Reach a Private Instance with Session Manager (Optional but Recommended)

You will live inside these instances during the troubleshooting labs, so connect to one now while everything is healthy.

15. **Start a Session Manager session** to the spoke A instance (no SSH, no key, no public IP - this works purely through the SSM interface endpoints):

    ```bash
    aws ssm start-session --target "$(terraform output -raw spoke_a_instance_id)"
    ```
    <!-- source: facts_extracted_v2.md §"Interface Endpoints (PrivateLink)" -->

16. **From inside the session**, confirm the two things Lab 1 and Lab 3 will later break:

    ```bash
    ping -c 3 SPOKE_B_IP            # replace with spoke_b_instance_private_ip output
    getent hosts app.lab.internal  # should resolve to a 10.106.x.x address
    exit
    ```
    <!-- source: facts_extracted_v2.md §"Transit Gateway" -->

**Expected Result:** The ping to spoke B succeeds (replies, 0% loss) and `app.lab.internal` resolves to a `10.106.x.x` address. This is the healthy behavior; remember it, because in Lab 1 the ping will hang and in Lab 3 the name will fail to resolve.

---

## Knowledge Check

**Question 1:** Your `terraform plan` before the first apply shows `Plan: 60 to add, 0 to change, 0 to destroy`. Later, after you fix a fault in Lab 1, a plan shows `1 to add, 0 to change, 0 to destroy`. What does the second plan tell you about the difference between current state and desired configuration?

> **Answer:** A plan reconciles real state against the configuration. `1 to add` means exactly one resource declared in the configuration does not currently exist in state - Terraform will create it to converge. After a fault that removed one route, that single missing resource is the route you are restoring. The `0 to change / 0 to destroy` confirms nothing else drifts as a side effect.

**Question 2:** The instances have no public IP, no NAT gateway, and no internet gateway, yet they register with Systems Manager and you can open a shell on them. By what path does that traffic flow, and which security group rule permits it?

> **Answer:** The instances reach the `ssm`, `ec2messages`, and `ssmmessages` services through **interface VPC endpoints (PrivateLink)** deployed in each spoke — the traffic never leaves the VPC boundary onto the internet. The endpoint security group allows inbound TCP 443 from the instance security group, referenced **by security-group ID** (the stateful SG-to-SG pattern), so only that spoke's instances can reach its endpoints.

**Question 3:** In `network.tf`, several resources use `count = local.is_labN ? 0 : 1`. In the healthy baseline you just deployed, what value does each of those `count` expressions evaluate to, and why does that matter for the rest of the course?

> **Answer:** With `scenario = "healthy"`, every `is_labN` local is `false`, so each guarded `count` evaluates to `1` and all guarded resources exist - the network is complete. Each later lab sets `scenario=labN`, flipping exactly one guard to `0`, which deletes one real resource. That single deletion is the injected fault you diagnose and then repair by editing the Terraform.

---

## Summary

You deployed a complete, private, AWS-native network with one `terraform apply`, learned to preview changes with `terraform plan`, and read the outputs that tie Terraform state to real resources. You confirmed the baseline with `verify.sh` and reached a private instance through Session Manager. This healthy stack is the canvas for every remaining lab.

## Completion Checklist

- [ ] `terraform init` succeeded
- [ ] `student_id` set in `terraform.tfvars`
- [ ] `terraform plan` reviewed (add-only on first deploy)
- [ ] `terraform apply` completed with an Outputs block
- [ ] Outputs read and mapped to the architecture (noted your account ID from the role ARN)
- [ ] `./verify.sh` reports ALL CHECKS PASSED
- [ ] Connected to spoke A via Session Manager; ping and DNS both worked

## Next Steps

In **Lab 1: Hub-Spoke Transit and Segmentation**, you inject your first fault 3 `scenario=lab1` removes a single VPC route, and spoke A loses its path to spoke B. You will prove the break with VPC Reachability Analyzer and Flow Logs, then repair it by editing the Terraform.

---

## Resources

- [Terraform CLI - apply](https://developer.hashicorp.com/terraform/cli/commands/apply)
- [AWS Transit Gateway User Guide](https://docs.aws.amazon.com/vpc/latest/tgw/)
- [Interface VPC endpoints (PrivateLink)](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Route 53 private hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
