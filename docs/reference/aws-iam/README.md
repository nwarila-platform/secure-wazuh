# AWS IAM — roles & privileges (reference)

**Type**: Reference (Diátaxis). This documents the AWS IAM that backs the ephemeral AWS PoC
(`terraform/aws.tfvars` + the `aws-terraform-framework`). The JSON here is the **authoritative
record** of the live IAM.

> **These roles/policies are created by hand, not by Terraform** (org convention: OIDC roles are
> provisioned directly, mirroring `github_nwarila-platform_github-terraform-runner[-admin]`). This
> folder is the source of truth for review; apply changes here first, then with `aws iam`.

## Roles

| Role | Trust | Attached policies | Purpose |
|---|---|---|---|
| `github_nwarila-platform_secure-wazuh` | GitHub OIDC → `main` | `github_nwarila-platform_secure-wazuh` (S3 state + artifact read) · `github_nwarila-platform_secure-wazuh_deploy` | CI deploy (OIDC, no long-lived keys) |
| `github_nwarila-platform_secure-wazuh-admin` | broker `AssumeRole` (≤1h) | `secure-wazuh-folder-admin` (inline, S3 folder admin) · `github_nwarila-platform_secure-wazuh_deploy` | Operator artifact management **and** local deploy via boxed creds |
| `secure-wazuh-poc-role` | `ec2.amazonaws.com` | `AmazonSSMManagedInstanceCore` (AWS-managed) · `secure-wazuh-poc-role-s3` (inline) | EC2 **instance profile** — SSM agent + S3 artifact read. Name contains `wazuh` to satisfy the deploy policy's `iam:PassRole` guard. |

The `_deploy` policy on the `-admin` role is a **deliberate, reversible deviation** from its
recorded S3-only duty — it lets the local `deploy → test → destroy` run under the boxed `-admin`
credentials while the CI OIDC path is unwired. Detach it once CI OIDC is live.

## Policies (`policies/`)

- **`secure-wazuh_deploy.json`** — the budget + security deploy policy (managed; attached to **both**
  roles). Implicit-deny by default; explicit-allow **only** for the exact 3-system spec:
  - instance types **`{m6i.xlarge, t3.medium}`** only, `default` tenancy, **IMDSv2 required**
    (`ec2:MetadataHttpTokens=required`), region **us-east-1** only;
  - EBS **gp3 ≤100 GB / ≤3000 IOPS / ≤125 MB/s** — with `ec2:ModifyVolume` split out and capped so a
    tagged volume can't be grown to `io2`;
  - **Identity — repository-id, not a name prefix (v5, migration complete 2026-07):** every
    mutating action is scoped to the immutable **`nwarila:management:repository-id = "1307854438"`**
    tag (secure-wazuh's GitHub repo id) — the interim `Name=secure-wazuh-poc*` + `Environment=poc`
    pair this replaces is gone from the policy entirely (so the teardown leg can never be denied —
    the record's primary cost control is destroy-always). The tag is stamped by the framework's
    *mandatory* deployment identity, never hand-set: `aws-terraform-framework` applies it (alongside
    `managed-by`/`repository`/`stack`/`environment`/`owner`/`commit-sha`/`run-id`) to every taggable
    resource through provider `default_tags`, **plus an explicit root-volume tag merge** —
    `default_tags` cannot reach an `aws_instance`'s implicitly-created root volume, so the framework
    issues a separate, follow-up tag call for it (see `StampRepoIdentityTags` below). **Deliberate
    trade:** the old name-prefix cap was a second, independent check layered on top of the tag;
    that layering is gone — identity is the tag alone now. The budget posture is unaffected: the
    type/size/region caps above are unchanged and do the actual cost-control work regardless of
    which tag key gates identity.
  - **PREREQUISITE:** every apply — CI and local alike — MUST export `TF_VAR_resource_metadata`
    (the framework's runner protocol; see `aws-terraform-framework`'s
    `docs/reference/runner-protocol.md`, "Deployment Identity Tags") before the first
    `RunInstances`/`CreateVolume`/`CreateNetworkInterface` call. Skip it and every
    `RequestTag/nwarila:management:repository-id` condition below is unsatisfied — every
    create-call in this policy is denied; there is no fallback identity.
  - **`StampRepoIdentityTags` (added 2026-07):** allows exactly `ec2:CreateTags` on
    `instance`/`volume`/`network-interface`/`security-group`, gated on the request itself carrying
    `RequestTag/nwarila:management:repository-id = "1307854438"` (region-locked too, no
    `ec2:DeleteTags` — removal stays exclusively on `LifecycleOnlyOnOurTaggedResources`). This is
    the permission the root-volume tag merge above needs: the root volume is born implicitly
    inside `RunInstances`, invisible to `default_tags`, so the provider tags it with a SEPARATE,
    standalone `CreateTags` call moments later — a call `TagOnlyAtCreateTime`'s `ec2:CreateAction`
    condition does not cover (that condition matches only tags bundled INSIDE the originating
    `RunInstances`/`CreateVolume`/`CreateNetworkInterface` call itself, not a follow-up call).
  - `iam:PassRole` limited to `role/*wazuh*` → `ec2`; KMS only via `ec2.us-east-1` for EBS; SSM
    `StartSession` (SSH-over-SSM) to our tagged instances.
  - **Security groups — framework-managed, per-system (added 2026-07):** `ec2:CreateSecurityGroup`
    (us-east-1) + `Authorize/Revoke/Modify/Delete` SG rules (us-east-1) + create-time `CreateTags` on
    SG / SG-rule resources — so the `aws-terraform-framework` can create each system's OWN
    system-specific SG (e.g. the AIO's inbound Wazuh mesh 1514/1515 from the deploy subnet).
    **Deliberately region-scoped, NOT rule-content- or `ResourceTag`-locked** (rationale: every system
    carries comprehensive per-system inbound/outbound rules; and a just-created SG-rule resource has no
    tag to match at authorize time, so `ResourceTag` scoping 403s). A conscious loosening of the
    exact-spec posture, for the SG surface only, bounded to us-east-1.
  - **Disk resolution (linux_disk_manager, added 2026-07):** the AWS disk resolver
    (`ansible-framework`'s `linux_disk_manager` role, `tasks/resolve_aws.yml`) runs a
    controller-side `ec2_vol_info` (`DescribeVolumes`) per target host to turn a declared
    `function` (EBS `Function` tag) into that volume's by-id `unique_id`. It relies entirely on
    this statement's existing `ec2:Describe*` (`ReadOnlyForTerraformAndDiscovery`) — the target
    instance itself needs no EBS/IAM grant of its own — so a future least-privilege narrowing of
    that Sid must keep `DescribeVolumes` or the disk resolver breaks.
  - Verified with `iam simulate-custom-policy` (per-statement, v5) before publish — 12/12:
    identity-stamped launches/lifecycle/SSM allowed; missing/foreign-identity, oversize type,
    IMDSv1, and wrong-region denied. Published as the policy's default version; confirmed LIVE
    two ways: (1) the deploy role stamped the standing SG's repository-id tag via the new
    `StampRepoIdentityTags` path — impossible under v4; (2) the previously-403ing OS-swap apply
    (a `refresh_serial` bump alongside a non-refresh sibling) re-ran with ZERO tag errors, and
    the sibling's root-volume tags converged.
- **`github_nwarila-platform_secure-wazuh.json`** — the CI role's S3 duty: read/write of this repo's
  Terraform state and its lock file under `<account-id>-terraform/<owner>/<repo>/`, plus read-only
  access to the Wazuh artifacts in `<account-id>-ansible`. Both targets keep their own state object
  (`aws.tfstate`, `proxmox.tfstate`), so the state statements are scoped to `*.tfstate` beneath that
  one repo prefix rather than to a single file. Two `Deny` statements require every state upload to
  carry `x-amz-server-side-encryption: AES256` — bucket-default encryption does **not** satisfy them,
  because the condition tests the request header, so the workflows pass `encrypt=true` to
  `terraform init`. Deleting a state object is denied outright; only the lock file may be removed.
- **`secure-wazuh-poc-role-s3.json`** — the instance profile's S3 artifact read (folder-scoped, read-only).

## Roles (`roles/`)

- **`secure-wazuh-poc-role.trust.json`** — the EC2 assume-role trust for the instance profile.

## Permanent networking (provisioned in AWS, left standing — not IAM)

A single **public subnet** the deployments land in (one shared deploy subnet for all systems):
auto-assign
public IP + a **no-inbound security group** (`secure-wazuh-poc-sg`, zero ingress, all egress) so the
SSM path works over the internet gateway with **no open ports** and no NAT/endpoint cost. Plus the
`secure-wazuh-poc-key` key pair (private key stays local; never committed). Named resources:
`secure-wazuh-igw`, `secure-wazuh-public-use1a`, `secure-wazuh-public-rt`, `secure-wazuh-poc-sg`.
`secure-wazuh-poc-sg` (`sg-06a3a06bcc4413c10`) carries a one-time, hand-stamped
`nwarila:management:repository-id = 1307854438` tag (replacing the retired `Environment=poc` note —
this SG is permanent/hand-provisioned, outside Terraform, so nothing re-applies the tag per run) so
the deploy role's `ResourceTag`-gated lifecycle actions keep working when they touch ENIs that
reference it alongside the framework-created per-system SGs.

**Per-system security groups (framework-managed, NOT standing):** the standing SG above stays
zero-inbound (SSM only). Each SYSTEM's own inbound/outbound firewall is a **per-deploy, framework-created
SG** (via `managed_security_groups` in the tfvars), added to that system's ENI alongside the standing
SG. The Wazuh AIO owns the manager's inbound mesh (`secure-wazuh-poc-aio`: tcp 1514/1515 from the deploy
subnet); agents only initiate outbound and ride the standing egress SG. Creating a shared, cross-system
rule is intentionally **not** the framework's role — each system defines its own.

## Cost & count backstops

IAM cannot cap instance **count** — a Budgets cost alarm (+ an us-east-1 4-vCPU On-Demand-Standard
quota request) is the backstop, paired with the deploy → test → **destroy** discipline.
