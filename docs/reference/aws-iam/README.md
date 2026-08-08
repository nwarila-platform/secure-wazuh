# AWS IAM — roles and privileges

**Type**: Reference (Diátaxis). This directory defines the IAM used by the ephemeral AWS PoC
(`terraform/aws.tfvars` plus `aws-terraform-framework`). An operator provisions the roles and
policies; Terraform does not manage them.

## Materialization and application

`<account-id>` is the repository's fail-fast tripwire for the real AWS account ID. Before applying
any source JSON, the operator replaces every exact `<account-id>` token with the org-global
`AWS_ACCOUNT_ID` in an untracked copy. A real 12-digit account ID must never be committed.

Materialize all files into one untracked directory, substitute the same account ID throughout,
and apply the trust documents, managed policies, inline policy, and attachments as one coordinated
change. Read each applied document and attachment back from IAM, normalize its JSON, and compare it
with the materialized source before granting access to a deployment.

## Role-to-policy map

| Role | Trust source | Required policies | Purpose |
|---|---|---|---|
| `github_nwarila-platform_secure-wazuh` | `roles/github_nwarila-platform_secure-wazuh.trust.json` | `github_nwarila-platform_secure-wazuh` · `github_nwarila-platform_secure-wazuh_deploy-ec2-launch` · `github_nwarila-platform_secure-wazuh_deploy-ec2-lifecycle` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | CI state, deploy, proof, destroy, and scoped artifact-reader assumption |
| `github_nwarila-platform_secure-wazuh-admin` | `roles/github_nwarila-platform_secure-wazuh-admin.trust.json` | `secure-wazuh-folder-admin` (inline) · `github_nwarila-platform_secure-wazuh_deploy-ec2-launch` · `github_nwarila-platform_secure-wazuh_deploy-ec2-lifecycle` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | Operator folder and artifact administration, local deploy, and scoped artifact-reader assumption |
| `secure-wazuh-artifact-reader` | `roles/secure-wazuh-artifact-reader.trust.json` | `secure-wazuh-artifact-read` | Deploy-time artifact reads through fresh 3,600-second sessions |
| `nwarila-ec2-role` | `roles/nwarila-ec2-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) | EC2 instance profile for SSM only; no standing S3 access |

Set `github_nwarila-platform_secure-wazuh`'s `MaxSessionDuration` role property to `3600`.
Set `nwarila-ec2-role`'s `MaxSessionDuration` role property to `3600`.

### The broker permission set — the half of this setup that is not in any repository

**Provisioning an `-admin` role does not make it assumable.** Its trust document names
`"Principal": {"AWS": "arn:aws:iam::<account-id>:root"}`, which *delegates* the decision to IAM
rather than granting it. The SSO identity must therefore **also** be allowed `sts:AssumeRole` by an
identity policy — and that policy lives in Identity Center, outside every repository in this org.

It is the inline policy of the **`github_nwarila-platform` permission set** (statement
`AssumeThisOrgsRepoAdminRoles`), which **enumerates repo-admin role ARNs explicitly**. A role absent
from that list is unassumable no matter how correct everything in this directory is.

`github_nwarila-platform_secure-wazuh-admin` **is** on that list, which is why this repository has
never hit the failure. **Repositories cloned from this pattern do not inherit it** — the list is
account state, not a file — and the omission is invisible from the clone: every source here is
correct, the gate passes, and `sts:AssumeRole` still returns

```
AccessDenied ... is not authorized to perform: sts:AssumeRole on resource:
arn:aws:iam::<account-id>:role/github_nwarila-platform_<repo>-admin
```

with no trailing `because no identity-based policy allows ...` clause to say which half failed.

**Diagnose in one command.** Assume this repo's `-admin` role from the same SSO session as the
failing one. Every repo-admin trust in this account is byte-identical, so if this one works and the
clone does not, the difference is the broker allowlist and nothing in the clone is wrong:

```bash
aws sts get-caller-identity --profile repoadmin-nwarila-platform-secure-wazuh   # known-good
aws iam get-role-policy --profile admin --policy-name AwsSSOInlinePolicy \
    --role-name "$(aws iam list-roles --profile admin --path-prefix /aws-reserved/sso.amazonaws.com/ \
        --query "Roles[?starts_with(RoleName,'AWSReservedSSO_github_nwarila-platform_')].RoleName | [0]" \
        --output text)"
```

**Fix** — privileged, needs the `AdministratorAccess` permission set. `put-inline-policy` **replaces
the whole document**, so include the ARNs already present:

```bash
INST=$(aws sso-admin list-instances --profile admin --query 'Instances[0].InstanceArn' --output text)
PS=...    # the permission set named github_nwarila-platform (sso-admin describe-permission-set)
aws sso-admin put-inline-policy-to-permission-set --profile admin \
    --instance-arn "$INST" --permission-set-arn "$PS" --inline-policy file://broker-inline.json
aws sso-admin provision-permission-set --profile admin \
    --instance-arn "$INST" --permission-set-arn "$PS" \
    --target-id <account-id> --target-type AWS_ACCOUNT
```

**Never** write it with `aws iam put-role-policy` against the `AWSReservedSSO_*` role. That appears
to work and is silently reverted the next time Identity Center provisions the permission set.

Verified 2026-07-30: this step was missed for both `windows-wsus` and `pdq-deploy-inventory` when
their `-admin` roles were created. **Adding the ARN is part of creating the role, not a follow-up** —
carry this instruction into every clone.

The four deploy policies on the `-admin` role support the local `deploy → test → destroy` path and
should be detached when that path is retired. EC2 uses instance profile
`nwarila-ec2-profile`, which contains `nwarila-ec2-role`; `iam:GetInstanceProfile` is
pinned to the profile and `iam:PassRole` is pinned to the role. Role-name substrings are not an
authorization boundary. The instance role carries only `AmazonSSMManagedInstanceCore`; it has no
artifact policy. Step 0 takes the instance IDs from the exact run-scoped server-plus-agent
topology, requires every instance to carry one common profile, and requires that profile object to
be `nwarila-ec2-profile`. It then requires exactly `nwarila-ec2-role`, exactly one
attachment whose ARN is the AWS-managed `AmazonSSMManagedInstanceCore` policy, and no inline
policies. It also reads the artifact bucket policy and rejects a resource-based Allow naming the
instance role. Absence of a bucket policy is acceptable; an unreadable policy is not. A retained
`secure-wazuh-artifact-read` attachment or bucket-policy grant therefore cannot pass deployment.
The complete boundary is checked again immediately before the first artifact fetch.

`secure-wazuh-artifact-read` is attached only to `secure-wazuh-artifact-reader`. Its trust names
exactly the CI and `-admin` deploy roles, and their shared discovery/IAM policy permits
`sts:AssumeRole` on exactly this role ARN. Each S3 read group requests a fresh 3,600-second session
and holds it on the controller. Every package attempt receives a fresh session and 900-second
signature; the dashboard listener pair receives a separate fresh session, is retrieved on the
controller, and is pushed. Registers, bearer facts, and session facts are overwritten after their
consumer completes. No instance receives a deploy or reusable standalone artifact-reader
credential. A package target does receive a bearer URL containing the temporary access-key
identifier and session token; it can be replayed for its one read-only object until expiry. The
`-admin` inline policy separately retains artifact write, read, deletion, tagging, and multipart
administration for operator work.

Do not attach `secure-wazuh-artifact-read` directly to either deploy role. A standing artifact-read
grant lets an artifact fetch succeed if it accidentally uses the ambient deploy credential, so a
successful deployment cannot establish that the assumed-reader credential signed the request.
Keeping the CI role free of direct artifact reads makes its assume-and-use path load-bearing. The
`-admin` role is an effective-permission exception: its folder-admin policy includes reads over the
same artifact prefixes for operator maintenance. A local deployment using that role therefore
cannot establish the credential path from fetch success alone. Separating routine local deployment
from artifact administration would remove that ambiguity.

Set `secure-wazuh-artifact-reader`'s `MaxSessionDuration` role property to `3600`. That is the
shortest value IAM accepts and the maximum available to this role-chained path. Signing is placed
immediately before each fetch attempt rather than at play start. A fetch gets up to three complete
mint-sign-fetch attempts with two 10-second delays. The 60-second module setting is a socket
inactivity timeout, not a wall-clock transfer cap, so it does not create a finite transfer budget
or expiry margin. Each retry instead owns a newly minted session and signature. Expiry is checked
when the HTTP request begins, so an active transfer can finish after that point.

The dashboard files follow the package fetch under a separately re-minted server session.
`dashboard-key.pem` (1,704 bytes), `dashboard-key.pem.sha256` (65 bytes), `dashboard.pem`
(1,281 bytes), and `dashboard.pem.sha256` (65 bytes) total 3,115 bytes (about 3.0 KiB). They are
retrieved directly by the controller, so they do not need a bearer URL. `MaxSessionDuration` is a
role property and is materialized alongside, not inside,
`roles/secure-wazuh-artifact-reader.trust.json`.

The `-admin` role is the human local-deploy and folder-administration path. Its trust allows
`sts:AssumeRole` from the account root principal only when `aws:PrincipalArn` matches the
organization's reserved `AWSReservedSSO_github_nwarila-platform_*` role. It is not assumed with web
identity, so GitHub OIDC claim conditions do not belong in its trust.

### Decision record — retain admin standing compute access

| Field | Value |
|---|---|
| Status | Accepted |
| Decision date | 2026-07-28 |
| Owner | @NWarila |
| Reconsider when | Local workstation deploys stop; `nwarila-ec2-role` gains any policy beyond `AmazonSSMManagedInstanceCore`; or the SSO permission set no longer requires MFA |

`github_nwarila-platform_secure-wazuh-admin` keeps the `deploy-ec2-launch`, `deploy-ec2-lifecycle`,
`deploy-sg-ssm-kms`, and `deploy-discovery-iam` compute-lifecycle policies that duplicate the CI
role's grants. The owner runs deploys from a workstation for development and testing as needed, so
`RunInstances` is part of this role's ordinary job. Splitting compute access into another role would
add friction to an active workflow without removing the need for human deploy authority.

Assumption requires an SSO login with MFA. The trust policy also requires `aws:PrincipalArn` to
match `AWSReservedSSO_github_nwarila-platform_*`; naming the account root as the principal does not
make the role reachable by other account principals. `MaxSessionDuration` is 3,600 seconds.

The `github_nwarila-platform` permission set behind that pattern is narrower than the trust alone
implies, and it is assigned to exactly one user. It attaches no managed policy; its only grant is
`sts:AssumeRole` to this admin role and the terraform-runner admin, so a compromised SSO session
holds no direct AWS API surface — it can only assume one of those two roles, under this role's own
boundary. Its session duration is one hour, matching the role's. These facts were read from the
Identity Center configuration; the MFA requirement itself is an Identity Center authentication
setting that has no API. The owner confirmed it enabled from the console on 2026-07-29 — that
console setting is the sole source of truth for this predicate, and it should be re-checked there
whenever this acceptance is revisited.

The accepted residual risk is material: `RunInstances` together with `iam:PassRole` on
`nwarila-ec2-role` permits an operator to launch an instance with arbitrary user data and that
instance profile. The launch boundary restricts the region, instance types, VPC, AMI owners, pinned
key pair, IMDSv2 setting, and repository-identity tag. The instance profile's privilege ceiling is
now SSM only because it carries `AmazonSSMManagedInstanceCore` and no other policy; it previously
also carried artifact-read access.

`secure-wazuh-folder-admin` grants artifact writes as well as reads. The admin role can therefore
replace the offline bundle, agent packages, dashboard listener pair, or digest sidecars in S3.
Verification divides into two custody classes. The offline bundle digest is committed in this
repository, and the agent RPM and MSI digests are committed in the `ansible-framework` revision
pinned by `.github/.framework-pin`; replacing any one of those three package objects alone fails
SHA-256 verification.

The dashboard listener pair is different. Its digests are `.sha256` sidecars in the same
admin-writable prefix, so an admin-role compromise can replace both PEMs and both sidecars together
and pass sidecar verification. The configured fingerprint or CA-chain check and login smoke test
still validate listener behavior, but they do not turn the sidecars into an independent trust
anchor. That shared custody is an accepted residual. The dashboard listener pair is the first
external artifact that moves into Ansible Vault when Vault custody is introduced.

Because `secure-wazuh-folder-admin` also grants artifact reads, a successful local deploy through
the admin role cannot prove that the artifact-reader role supplied the read credential. CI proves
the reader-role path because its deploy role has no direct artifact-read grant; local success
cannot.

## GitHub OIDC trust

`roles/github_nwarila-platform_secure-wazuh.trust.json` defines the CI role trust. It requires all
of these claims:

- `aud = sts.amazonaws.com`;
- `sub` matching either `repo:nwarila-platform@230745524/secure-wazuh@1307854438:*` or
  `repo:nwarila-platform/secure-wazuh:*`;
- the immutable repository identity `repository_id = 1307854438`;
- `job_workflow_ref` matching either
  `nwarila-platform/secure-wazuh/.github/workflows/deploy.yml@*` or
  `nwarila-platform/secure-wazuh/.github/workflows/aws-deploy.yml@*`.

The `deploy.yml` pattern remains in the source trust, but that workflow no longer contains an AWS
job or grants `id-token: write`. `aws-deploy.yml` is the only credentialed AWS workflow.

### Repository OIDC claims

The live credentialed workflow emits GitHub's standard repository subject form,
`repo:<owner>/<repo>:<context>`. The ID-embedded alternative in the source trust document has not
been a live token subject; it remains an additional accepted pattern, not a description of emitted
behavior. The `job_workflow_ref` claim is present on ordinary, non-reusable workflow jobs and has
the value `<owner>/<repo>/.github/workflows/<file>@<ref>`. The `repository_id` claim is
`1307854438` and is emitted on every run.

The repository-scoped `sub` gate does not restrict branches. Apply the document as a complete
replacement so no ref-based or temporary feature-branch subjects remain.

Branch selection stays in the workflows' trigger logic instead of the role trust. Their `paths:`
filters cover `.github/.framework-pin`, `.github/.aws-tf-framework-pin`, `ansible/**`,
`terraform/aws.tfvars`, and the workflow file itself. The Terraform filter names that one file
deliberately: `terraform/**` also matched `terraform/proxmox.tfvars`, so editing a Proxmox variable
fired a real AWS deploy. `ansible/**` stays whole because the Compose step rsyncs it wholesale onto
the framework tree, so any file under it can shadow framework content. The Wazuh version is the `bundle_key` in
`ansible/applications/wazuh_server/vars/redhat_dev.yml`, so version changes remain covered by the
`ansible/**` filter. A `pull_request` run of `aws-deploy.yml` can therefore authenticate without a
loose `pull_request` subject: the trust does not key authorization on the event.

The `@*` suffix is a deliberate, accepted risk: it admits any ref's copy of those two workflow
files, including a modified version. Repository write access already equals deploy authority here,
so pinning specific refs would add IAM churn without adding a real boundary.

Before applying the trust, inspect an `aws-deploy.yml` token and confirm that `repository_id` and
`job_workflow_ref` have the exact values required by the document. Confirm that workflow can
authenticate after application.

The event-path boundary forbids any workflow that combines
`pull_request_target` with `id-token: write`. The organization setting that sends write tokens to
workflows from fork pull requests MUST remain disabled. With that required setting, GitHub does not
mint an ID token to fork `pull_request` runs; the `id-token` permission is write-or-none. The
same-repository guard in `aws-deploy.yml` also excludes fork PRs before the credentialed job, but it
does not replace that organization-level dependency.

## Deploy policy split and controls

The deploy boundary uses four managed policies:

- `policies/secure-wazuh_deploy-ec2-launch.json` →
  `github_nwarila-platform_secure-wazuh_deploy-ec2-launch`;
- `policies/secure-wazuh_deploy-ec2-lifecycle.json` →
  `github_nwarila-platform_secure-wazuh_deploy-ec2-lifecycle`;
- `policies/secure-wazuh_deploy-discovery-iam.json` →
  `github_nwarila-platform_secure-wazuh_deploy-discovery-iam`;
- `policies/secure-wazuh_deploy-sg-ssm-kms.json` →
  `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms`.

The split is structural. Do not recreate one combined document. Attach all four policies to
**both** deploy-capable roles before detaching the old
`github_nwarila-platform_secure-wazuh_deploy` policy. Detaching first creates a permissions outage;
leaving the old policy attached temporarily preserves its old broad permissions.

EC2 is two policies, not one, because a single document had 513 characters of headroom against the
6,144 limit — too little to add a control without evicting another. `-launch` holds the
`RunInstances` admission controls (what may be created); `-lifecycle` holds tagging and mutation of
what already exists.

The earlier combined `secure-wazuh_deploy-ec2.json` was retired on 2026-08-03. It had been detached
from every role since the live split on 2026-07-29 while remaining a tracked source, so edits to it
changed nothing — see `docs/decision-records/repo/0006-live-attachment-is-part-of-the-contract.md`.

AWS ignores whitespace when enforcing the 6,144-character managed-policy limit. The compact
source sizes and remaining headroom are:

| Policy source | Compact characters | Headroom |
|---|---:|---:|
| `github_nwarila-platform_secure-wazuh.json` | 1,449 | 4,695 |
| `secure-wazuh-artifact-read.json` | 800 | 5,344 |
| `secure-wazuh-folder-admin.json` | 4,392 | 1,752 |
| `secure-wazuh_deploy-ec2-launch.json` | 3,040 | 3,104 |
| `secure-wazuh_deploy-ec2-lifecycle.json` | 3,302 | 2,842 |
| `secure-wazuh_deploy-discovery-iam.json` | 1,651 | 4,493 |
| `secure-wazuh_deploy-sg-ssm-kms.json` | 3,488 | 2,656 |

The EC2 policy defines these cost and security controls:

- `us-east-1` only; instance types exactly `{m6i.xlarge, t3.medium}`; default tenancy; IMDSv2
  required at launch;
- gp3 volumes no larger than 100 GiB, 3000 IOPS, or 125 MiB/s, including later
  `ModifyVolume`; `NumericLessThanEqualsIfExists` remains intentional for optional gp3
  IOPS/throughput inputs;
- create authorization uses the request identity tag and lifecycle authorization uses the
  resource identity tag `RepositoryId = 1307854438`;
- `RunInstancesImagesFromTrustedOwners` implements the achievable owner boundary recorded in
  [ADR-0005](../../decision-records/repo/0005-guard-placement-by-direction.md):
  `{amazon, aws-marketplace, <account-id>}`. IAM evaluates the Marketplace image's owner alias, and
  the account entry is forward-looking for images built here. The key-pair leg is pinned to
  `nwarila-ec2-key`;
- ENI creation requires the repository identity tag on the new network-interface authorization
  leg. The `RunInstances` network-interface, subnet, and security-group legs and the
  `CreateNetworkInterface` subnet and security-group legs are restricted to the deploy VPC; both
  subnet legs are additionally pinned to `subnet-0e1c8aae192deff26`;
- runtime metadata changes on owned instances permit other metadata-option edits, but an explicit
  `ec2:MetadataHttpTokens` input can only be `required`;
- console output is tag-scoped.

The discovery and IAM policy keeps Terraform's EC2 read-only discovery action allowlist in
`us-east-1`, limits instance-profile discovery to `nwarila-ec2-profile`, permits only the two
role-policy list calls needed to reject the legacy policy on `nwarila-ec2-role`, permits the
artifact-bucket policy read needed to reject a resource-based role grant, permits passing only that
role to EC2, and permits assuming only `secure-wazuh-artifact-reader`.

`ec2:DescribeInstances` stays in the existing `DescribeEc2ForTerraformAndDiscovery` statement.
The profile guard therefore needs no additional EC2 statement. Add the S3 read to
`github_nwarila-platform_secure-wazuh_deploy-discovery-iam`, which is attached to both deploy
roles:

```json
{
  "Sid": "InspectArtifactBucketPolicy",
  "Effect": "Allow",
  "Action": "s3:GetBucketPolicy",
  "Resource": "arn:aws:s3:::<account-id>-ansible",
  "Condition": {
    "StringEquals": {
      "aws:ResourceAccount": "<account-id>"
    }
  }
}
```

This read-only boundary inspection belongs with discovery and IAM reads, not in the
`github_nwarila-platform_secure-wazuh_deploy-ec2-launch` / `-lifecycle` pair. Those two are
reserved for EC2 admission and mutation respectively.

Every CI and local apply must export `TF_VAR_resource_metadata` before Terraform creates any
resource. The pinned framework supplies the identity tags through provider `default_tags` and
includes them in the `RunInstances` tag specifications for both instances and volumes. Its
follow-up root-volume tag merge therefore operates on a volume that already carries the identity,
and the volume authorization leg requires that identity in the launch request.

`StampRepoIdentityTagOnRootVolumes` is the only standalone tag allow. It is limited to EBS volumes
that already carry the repository identity, and the request must carry that same identity value.
This permits the provider's follow-up merge without allowing an untagged volume to be claimed.
Standalone tagging of instances, ENIs, security groups, and untagged volumes is not allowed.
Explicit Denies prevent overwriting a foreign repository identity, setting the identity to another
value, or deleting the identity key.

The second deploy policy defines the remaining surfaces:

- security-group creation and group actions are pinned to VPC `vpc-03c38504869c1c9bb`; group
  mutation/deletion also requires the repository identity resource tag. Security-group-rule
  resources stay region-scoped because EC2 exposes the VPC context on the parent group
  authorization, not the rule resource. Framework-created, repository-tagged interface groups
  remain manageable through deployment and teardown;
- SSM `StartSession` remains tag-scoped to owned instances and the
  `AWS-StartSSHSession` document; resume/terminate is region-scoped to session resources. An assumed
  role's `${aws:userid}` contains the role ID and session name separated by a colon, so using it as
  a session ARN prefix would not match the SSM session ID and would silently deny teardown;
- Terraform can call `kms:ListAliases` and `kms:DescribeKey` directly in `us-east-1`. EBS
  cryptographic operations and grants are pinned to the AWS-managed key currently resolved by
  `alias/aws/ebs`; automatic rotation changes its key material without changing the logical key
  ARN. Cryptographic operations require `kms:ViaService = ec2.us-east-1.amazonaws.com`;
  `kms:CreateGrant` is separate and additionally requires `kms:GrantIsForAWSResource = true`. A
  clone must resolve its own `alias/aws/ebs` target and replace the committed key ID before applying
  this policy.

### Accepted deploy residual risk

The image-publisher boundary, guard placement, and public-addressing residual are recorded once in
[ADR-0005](../../decision-records/repo/0005-guard-placement-by-direction.md).

The deploy role's required EC2 permissions leave two paths that IAM cannot constrain:

- `RunInstances` accepts arbitrary user data on an otherwise permitted image. Amazon EC2 exposes no
  IAM condition key for user data, so compromised deploy credentials can use it to execute
  attacker-controlled code on an image admitted by the trusted-owner boundary.
- The role must manage its repository-tagged security groups, but Amazon EC2 exposes no IAM
  condition key for an ingress rule's CIDR. Compromised deploy credentials can therefore authorize
  `0.0.0.0/0` directly. The framework's world-open ingress validation is a Terraform-time guard; it
  does not constrain direct EC2 API calls.

Reducing these risks requires account-side enforcement or a different deployment architecture. An
SCP can deny whole EC2 operations or principals but cannot inspect user data or an ingress CIDR
without corresponding EC2 condition keys. Examples that do reduce exposure are moving launch and
security-group mutation behind a separately controlled path, or an event-driven reaper keyed on the
repository identity tag that terminates nonconforming instances and revokes nonconforming rules.

## S3 policies

- `github_nwarila-platform_secure-wazuh.json` grants state/lock access only under
  `<account-id>-terraform/nwarila-platform/secure-wazuh/`. State-bucket listing is scoped to this
  repository's key prefix plus Terraform's `env:/` workspace-enumeration prefix.
  `DenyDeleteStateFile` covers current objects and versions. The paired encryption Denies still
  require an explicit `AES256` request header; bucket-default encryption alone does not satisfy
  them.
- `secure-wazuh-artifact-read.json` is attached only to `secure-wazuh-artifact-reader` and grants
  object/version reads and prefix listing under
  `functions/wazuh/*` and `applications/wazuh-agent/*`, plus the bucket-location read in
  `<account-id>-ansible`. Those prefixes contain only the offline bundle, the dashboard listener
  pair and sidecars, and the two agent packages, so the unchanged prefix grant is minimal in
  practice.
- `secure-wazuh-folder-admin.json` retains the admin role's repository-folder and Wazuh-artifact
  object administration, including multipart cleanup; scoped bucket listing and location reads;
  confinement, public/cross-account, charge-incurring, bucket-lifecycle, and encryption Denies.

Every S3 Allow that addresses a repository bucket uses the account-named bucket ARN and
`aws:ResourceAccount = <account-id>`. Cross-account artifact access is not implicit; if it becomes
a requirement, add a separate explicit statement with its own approval boundary.

Terraform state remains SSE-S3 (`AES256`). Moving it to SSE-KMS requires a selected CMK, bucket
configuration, backend configuration, key policy, and tested recovery path; it is deliberately
not represented as complete by an IAM-only edit.

## PoC networking

The deployments use public subnet `subnet-0e1c8aae192deff26` in
`vpc-03c38504869c1c9bb` and SSH key pair `nwarila-ec2-key`. Each
`network_interfaces` entry declares its own `ingress` and `egress`; the framework derives
`<hostname>-eni-<index>-sg` and attaches that group only to the declaring interface.
`security_groups` is reserved for pre-created group IDs, and all three interfaces currently set it
to `[]`.

The AIO interface admits TCP 1514/1515 and TCP 443 from `10.1.10.0/24`; it does not admit inbound
SSH, 9200, 9300, or 55000. The Linux and Windows agent interfaces admit no inbound traffic. All
three interface groups independently allow all outbound traffic, so administrative access is SSH
over SSM.

## Cost and count backstops

IAM cannot cap instance count, and this repository does not establish the account's live EC2 quota
or budget-alarm state. A 4-vCPU quota and a budget alarm are separate account-side backstops that
must exist before they can be relied upon. The workflow itself supplies the repository-visible
deploy → prove → destroy path.
