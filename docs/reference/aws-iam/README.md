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
| `github_nwarila-platform_secure-wazuh` | `roles/github_nwarila-platform_secure-wazuh.trust.json` | `github_nwarila-platform_secure-wazuh` · `secure-wazuh-artifact-read` · `github_nwarila-platform_secure-wazuh_deploy-ec2` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | CI state, artifact read, deploy, proof, and destroy |
| `github_nwarila-platform_secure-wazuh-admin` | `roles/github_nwarila-platform_secure-wazuh-admin.trust.json` | `secure-wazuh-folder-admin` (inline) · `secure-wazuh-artifact-read` · `github_nwarila-platform_secure-wazuh_deploy-ec2` · `github_nwarila-platform_secure-wazuh_deploy-discovery-iam` · `github_nwarila-platform_secure-wazuh_deploy-sg-ssm-kms` | Operator folder and artifact administration, and local deploy with boxed credentials |
| `secure-wazuh-poc-role` | `roles/secure-wazuh-poc-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) · `secure-wazuh-artifact-read` | EC2 instance profile for SSM and read-only artifact access |

The three deploy policies on the `-admin` role support the local `deploy → test → destroy` path and
should be detached when that path is retired. EC2 uses instance profile
`secure-wazuh-poc-profile`, which contains `secure-wazuh-poc-role`; `iam:GetInstanceProfile` is
pinned to the profile and `iam:PassRole` is pinned to the role. Role-name substrings are not an
authorization boundary.

`secure-wazuh-artifact-read` is the customer-managed policy the CI, `-admin`, and instance-profile
roles require. The repository records the source documents and required attachment model; it
cannot establish the live attachment state. The `-admin` inline policy separately defines artifact
write, deletion, tagging, and multipart administration.

The `-admin` role is the human/break-glass path. Its trust allows `sts:AssumeRole` from the account
root principal only when `aws:PrincipalArn` matches the organization's reserved
`AWSReservedSSO_github_nwarila-platform_*` role. It is not assumed with web identity, so GitHub
OIDC claim conditions do not belong in its trust.

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

### Repository OIDC claims

The live workflows emit GitHub's standard repository subject form,
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

Before applying the trust, inspect a token from each credentialed workflow and confirm that
`repository_id` and `job_workflow_ref` have the exact values required by the document. Confirm both
workflows can authenticate after application.

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
| `secure-wazuh_deploy-ec2.json` | 5,471 | 673 |
| `secure-wazuh_deploy-discovery-iam.json` | 1,090 | 5,054 |
| `secure-wazuh_deploy-sg-ssm-kms.json` | 3,678 | 2,466 |

The EC2 policy defines these cost and security controls:

- `us-east-1` only; instance types exactly `{m6i.xlarge, t3.medium}`; default tenancy; IMDSv2
  required at launch;
- gp3 volumes no larger than 100 GiB, 3000 IOPS, or 125 MiB/s, including later
  `ModifyVolume`; `NumericLessThanEqualsIfExists` remains intentional for optional gp3
  IOPS/throughput inputs;
- create authorization uses the request identity tag and lifecycle authorization uses the
  resource identity tag `nwarila:management:repository-id = 1307854438`;
- ENI creation requires the repository identity tag on the new network-interface authorization
  leg. The `RunInstances` network-interface, subnet, and security-group legs and the
  `CreateNetworkInterface` subnet and security-group legs are restricted to the deploy VPC; both
  subnet legs are additionally pinned to `subnet-0e1c8aae192deff26`;
- runtime metadata changes on owned instances permit other metadata-option edits, but an explicit
  `ec2:MetadataHttpTokens` input can only be `required`;
- console output is tag-scoped.

The discovery and IAM policy keeps Terraform's EC2 read-only discovery action allowlist in
`us-east-1`, limits instance-profile discovery to `secure-wazuh-poc-profile`, and permits passing
only `secure-wazuh-poc-role` to EC2.

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

## S3 policies

- `github_nwarila-platform_secure-wazuh.json` grants state/lock access only under
  `<account-id>-terraform/nwarila-platform/secure-wazuh/`. State-bucket listing is scoped to this
  repository's key prefix plus Terraform's `env:/` workspace-enumeration prefix.
  `DenyDeleteStateFile` covers current objects and versions. The paired encryption Denies still
  require an explicit `AES256` request header; bucket-default encryption alone does not satisfy
  them.
- `secure-wazuh-artifact-read.json` grants object/version reads and prefix listing under
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
