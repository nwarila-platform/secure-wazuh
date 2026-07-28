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
| `github_nwarila-platform_secure-wazuh` | `roles/github_nwarila-platform_secure-wazuh.trust.json` | `github_nwarila-platform_secure-wazuh` · `github_nwarila-platform_secure-wazuh_deploy-ec2` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | CI state, deploy, proof, destroy, and scoped artifact-reader assumption |
| `github_nwarila-platform_secure-wazuh-admin` | `roles/github_nwarila-platform_secure-wazuh-admin.trust.json` | `secure-wazuh-folder-admin` (inline) · `github_nwarila-platform_secure-wazuh_deploy-ec2` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | Operator folder and artifact administration, local deploy, and scoped artifact-reader assumption |
| `secure-wazuh-artifact-reader` | `roles/secure-wazuh-artifact-reader.trust.json` | `secure-wazuh-artifact-read` | Deploy-time artifact reads through fresh 3,600-second sessions |
| `secure-wazuh-poc-role` | `roles/secure-wazuh-poc-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) | EC2 instance profile for SSM only; no standing S3 access |

The three deploy policies on the `-admin` role support the local `deploy → test → destroy` path and
should be detached when that path is retired. EC2 uses instance profile
`secure-wazuh-poc-profile`, which contains `secure-wazuh-poc-role`; `iam:GetInstanceProfile` is
pinned to the profile and `iam:PassRole` is pinned to the role. Role-name substrings are not an
authorization boundary. The instance role carries only `AmazonSSMManagedInstanceCore`; it has no
artifact policy and cannot read the S3 bucket. Step 0 reads this live profile before any target
work, requires exactly that role, and fails closed unless it has exactly one attachment whose ARN
is the AWS-managed `AmazonSSMManagedInstanceCore` policy, with no inline policies. A retained
`secure-wazuh-artifact-read` attachment therefore cannot pass deployment.

`secure-wazuh-artifact-read` is attached only to `secure-wazuh-artifact-reader`. Its trust names
exactly the CI and `-admin` deploy roles, and their shared discovery/IAM policy permits
`sts:AssumeRole` on exactly this role ARN. Each S3 read group requests a fresh 3,600-second session
and holds it on the controller. Every package attempt receives a fresh session and 900-second
signature; the dashboard listener pair receives a separate fresh session, is retrieved on the
controller, and is pushed. Registers, bearer facts, and session facts are overwritten after their
consumer completes. No instance receives deploy or standalone artifact-reader authority. The
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

The dashboard files follow the package fetch under a separately re-minted server session. They
total only about 1.7 KiB and are retrieved directly by the controller, so they do not need a
bearer URL. `MaxSessionDuration` is a role property and is materialized alongside, not inside,
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
| Reconsider when | Local workstation deploys stop; `secure-wazuh-poc-role` gains any policy beyond `AmazonSSMManagedInstanceCore`; or the SSO permission set no longer requires MFA |

`github_nwarila-platform_secure-wazuh-admin` keeps the `deploy-ec2`,
`deploy-sg-ssm-kms`, and `deploy-discovery-iam` compute-lifecycle policies that duplicate the CI
role's grants. The owner runs deploys from a workstation for development and testing as needed, so
`RunInstances` is part of this role's ordinary job. Splitting compute access into another role would
add friction to an active workflow without removing the need for human deploy authority.

Assumption requires an SSO login with MFA. The trust policy also requires `aws:PrincipalArn` to
match `AWSReservedSSO_github_nwarila-platform_*`; naming the account root as the principal does not
make the role reachable by other account principals. `MaxSessionDuration` is 3,600 seconds.

The accepted residual risk is material: `RunInstances` together with `iam:PassRole` on
`secure-wazuh-poc-role` permits an operator to launch an instance with arbitrary user data and that
instance profile. The launch boundary restricts the region, instance types, VPC, AMI owners, pinned
key pair, IMDSv2 setting, and repository-identity tag. The instance profile's privilege ceiling is
now SSM only because it carries `AmazonSSMManagedInstanceCore` and no other policy; it previously
also carried artifact-read access.

`secure-wazuh-folder-admin` grants artifact writes as well as reads. The admin role can therefore
replace the offline bundle or agent packages in S3. The deploy verifies each artifact against a
SHA-256 value committed in this repository, so changing an S3 object alone cannot substitute a
different payload successfully. The S3 boundary by itself is not the safe residual; the committed
digest check is the compensating integrity control.

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
  `nwarila-platform/secure-wazuh/.github/workflows/e2e-full.yml@*`.

The `deploy.yml` pattern remains in the source trust, but that workflow no longer contains an AWS
job or grants `id-token: write`. `e2e-full.yml` is the only credentialed AWS workflow.

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
`terraform/**`, and the workflow file itself. The Wazuh version is the `bundle_key` in
`ansible/applications/wazuh_server/vars/redhat_dev.yml`, so version changes remain covered by the
`ansible/**` filter. A `pull_request` run of `e2e-full.yml` can therefore authenticate without a
loose `pull_request` subject: the trust does not key authorization on the event.

The `@*` suffix is a deliberate, accepted risk: it admits any ref's copy of those two workflow
files, including a modified version. Repository write access already equals deploy authority here,
so pinning specific refs would add IAM churn without adding a real boundary.

Before applying the trust, inspect an `e2e-full.yml` token and confirm that `repository_id` and
`job_workflow_ref` have the exact values required by the document. Confirm that workflow can
authenticate after application.

The event-path boundary forbids any workflow that combines
`pull_request_target` with `id-token: write`. The organization setting that sends write tokens to
workflows from fork pull requests MUST remain disabled. With that required setting, GitHub does not
mint an ID token to fork `pull_request` runs; the `id-token` permission is write-or-none. The
same-repository guard in `e2e-full.yml` also excludes fork PRs before the credentialed job, but it
does not replace that organization-level dependency.

## Deploy policy split and controls

The deploy boundary uses three managed policies:

- `policies/secure-wazuh_deploy-ec2.json` →
  `github_nwarila-platform_secure-wazuh_deploy-ec2`;
- `policies/secure-wazuh_deploy-discovery-iam.json` →
  `github_nwarila-platform_secure-wazuh_deploy-discovery-iam`;
- `policies/secure-wazuh_deploy-sg-ssm-kms.json` →
  `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms`.

The split is structural. Do not recreate one combined document. Attach all three policies to
**both** deploy-capable roles before detaching the old
`github_nwarila-platform_secure-wazuh_deploy` policy. Detaching first creates a permissions outage;
leaving the old policy attached temporarily preserves its old broad permissions.

AWS ignores whitespace when enforcing the 6,144-character managed-policy limit. The compact
source sizes and remaining headroom are:

| Policy source | Compact characters | Headroom |
|---|---:|---:|
| `github_nwarila-platform_secure-wazuh.json` | 1,634 | 4,510 |
| `secure-wazuh-artifact-read.json` | 800 | 5,344 |
| `secure-wazuh-folder-admin.json` | 4,392 | 1,752 |
| `secure-wazuh_deploy-ec2.json` | 5,621 | 523 |
| `secure-wazuh_deploy-discovery-iam.json` | 1,425 | 4,719 |
| `secure-wazuh_deploy-sg-ssm-kms.json` | 3,678 | 2,466 |

The EC2 policy defines these cost and security controls:

- `us-east-1` only; instance types exactly `{m6i.xlarge, t3.medium}`; default tenancy; IMDSv2
  required at launch;
- gp3 volumes no larger than 100 GiB, 3000 IOPS, or 125 MiB/s, including later
  `ModifyVolume`; `NumericLessThanEqualsIfExists` remains intentional for optional gp3
  IOPS/throughput inputs;
- create authorization uses the request identity tag and lifecycle authorization uses the
  resource identity tag `nwarila:management:repository-id = 1307854438`;
- the image authorization leg accepts only AMIs with the `amazon` or `aws-marketplace`
  `ec2:Owner` alias, and the key-pair leg is pinned to `secure-wazuh-poc-key`;
- ENI creation requires the repository identity tag on the new network-interface authorization
  leg. The `RunInstances` network-interface, subnet, and security-group legs and the
  `CreateNetworkInterface` subnet and security-group legs are restricted to the deploy VPC; both
  subnet legs are additionally pinned to `subnet-0e1c8aae192deff26`;
- runtime metadata changes on owned instances permit other metadata-option edits, but an explicit
  `ec2:MetadataHttpTokens` input can only be `required`;
- console output is tag-scoped.

The discovery and IAM policy keeps Terraform's EC2 read-only discovery action allowlist in
`us-east-1`, limits instance-profile discovery to `secure-wazuh-poc-profile`, permits only the two
role-policy list calls needed to reject the legacy policy on `secure-wazuh-poc-role`, permits
passing only that role to EC2, and permits assuming only `secure-wazuh-artifact-reader`.

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

The deploy role's required EC2 permissions leave two paths that IAM cannot constrain:

- `RunInstances` accepts arbitrary user data on an otherwise permitted image. Amazon EC2 exposes no
  IAM condition key for user data, so compromised deploy credentials can use it to execute
  attacker-controlled code on an `amazon` or `aws-marketplace` image.
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
`vpc-03c38504869c1c9bb` and SSH key pair `secure-wazuh-poc-key`. Each
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
