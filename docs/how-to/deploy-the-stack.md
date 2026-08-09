# How to deploy the Wazuh all-in-one stack

**Type**: How-to (Diátaxis). For topology facts see [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md); for the artifacts this pulls from S3 see [`reference/s3-artifacts.md`](../reference/s3-artifacts.md); for credential handling see [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md); for why the run happens inside a composed tree see [`explanation/composition-model.md`](../explanation/composition-model.md).

This guide takes a freshly applied AWS proof-of-concept environment and brings up the collapsed Wazuh all-in-one (AIO) stack — OpenSearch indexer, manager, Filebeat, and dashboard on one host — plus both endpoint agent platforms, and then proves a real File Integrity Monitoring event on each.

The AWS target is **exactly two orchestration files**: the dynamic inventory
`ansible/inventory/aws/aws_ec2.yml` and the single playbook
`ansible/playbooks/deploy-aws-poc.yml`. There is no `group_vars/` directory and no second
playbook — connection facts live in the inventory's `compose:` block; deployment inputs come
from the playbook and the controller environment.

The permanent Proxmox target is **parked**: its job in [`deploy.yml`](../../.github/workflows/deploy.yml) is gated off and no playbook currently drives it. `ansible/inventory/proxmox.yml` is still committed as the inventory that target will use again.

## Prerequisites

- **A controller with the pinned toolchain.** Install the development dependencies from `requirements-dev.txt`: `ansible-core >=2.16,<2.17`, `ansible-lint 24.x`, `yamllint`. The runtime collections (`ansible.posix <2`, `community.general <8`, `amazon.aws`, `ansible.windows`) come from `ansible/requirements.yml`. The version ceiling is deliberate — see [`explanation/toolchain-rhel8.md`](../explanation/toolchain-rhel8.md).
- **A composed run tree.** The product roles under `ansible/applications/` resolve fully only when
  overlaid onto the pinned `ansible-framework` loader. CI composes this automatically. For local
  runs, reproduce the workflow's pinned checkout and overlay steps in an ignored `_dev-build/`
  tree, then run every Ansible command from inside it. This repository does not ship a compose
  helper. See [`explanation/composition-model.md`](../explanation/composition-model.md).
- **`boto3`/`botocore` on the controller.** Dynamic inventory, artifact-reader assumption, local
  signing, dashboard-pair retrieval, and the delegated EBS Function-tag resolver use the
  controller's interpreter. Targets need no AWS SDK.
- **The SSM Session Manager plugin on the controller.** None of the interface-owned security
  groups permits inbound SSH, so every SSH/SFTP/SCP call is tunnelled through
  `aws ssm start-session`; that ProxyCommand shells out to a separate binary the AWS CLI does not
  bundle.
- **Artifacts staged in S3.** Upload the `wazuh-offline.tar.gz` bundle and record its SHA-256 in
  `s3.bundle_sha256`; upload `dashboard.pem`, `dashboard-key.pem`, and each PEM's `.sha256`
  sidecar under `s3.certs_prefix`; upload the agent RPM/MSI and record their SHA pins. The
  internal PKI is minted on the AIO target and never transits S3; the dashboard listener pair is
  the only certificate material S3 holds. Object names and pins are catalogued in
  [`reference/s3-artifacts.md`](../reference/s3-artifacts.md). The bucket itself is never
  committed; workflows export `ANSIBLE_S3_BUCKET` from their existing account-id-derived value,
  and local operators export the bucket name explicitly (ADR-0004).
- **An ambient AWS deploy identity and region on the controller.** Terraform, inventory, SSM, the
  delegated EBS resolver, and `sts:AssumeRole` use the normal SDK configuration. The playbook never
  copies that identity to a target. GitHub workflows also export `ARTIFACT_READER_ROLE_ARN`; local
  operators export the same non-secret ARN. The playbook keeps each artifact-reader session on
  the controller, signs a 900-second URL per host attempt, and pushes the dashboard listener pair —
  see
  [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md).
- **No operator-supplied Wazuh secret.** Stage 1 mints the OpenSearch/dashboard `admin` password
  for each invocation. Other Wazuh credentials rotate with it, and the guarded manager-API ladder
  converges values already stored in persistent `rbac.db`. AWS access and connection credentials
  remain prerequisites as listed above.

## Procedure: deploy

Everything below runs from inside the composed tree.

```bash
# Required non-secret artifact-bucket input for local operation.
ansible_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/secure-wazuh-ansible.XXXXXX")"
export ANSIBLE_LOCAL_TEMP="${ansible_temp_root}/local"
mkdir -p "${ANSIBLE_LOCAL_TEMP}"
trap 'rm -rf -- "${ansible_temp_root}"' EXIT
export ANSIBLE_S3_BUCKET='your-org-artifact-bucket-name'
export ARTIFACT_READER_ROLE_ARN='arn:aws:iam::<account-id>:role/secure-wazuh-artifact-reader'

# Static gates.
PYTHONUTF8=1 yamllint .
ansible-lint

# Syntax and inventory resolution.
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml --syntax-check
ansible-inventory -i inventory/aws/aws_ec2.yml --graph

# Deploy + prove, in one command. No --extra-vars, ever.
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

That one playbook runs, in order: propagate the `dev` tier; prepare Linux with platform-python
only and validate the Windows session; provision and mount `/mnt/data`; mint the run's ephemeral
admin password; then deploy the server and both agent platforms. Each package read mints a fresh
controller session, signs once beside use, and fans the same URL out to its target batch. The
dashboard pair instead moves through controller staging. The play then runs the Linux and Windows
FIM triggers, appends their markers to the cumulative ledger on `/mnt/data`, and proves every
ledger entry reached `wazuh-alerts-*` as an endpoint-agent event (`agent.id != 000`).

This AWS target requires exactly one AIO, one Linux agent, and one Windows agent. Step 0 rejects an
empty, partial, or duplicate run-scoped inventory before any target work begins.

### Environment selection

`ENV: 'dev'` is propagated literally to every target — this playbook targets exactly one
environment, so there is nothing to parameterize.

### Run-scoped inventory

In GitHub Actions, `GITHUB_RUN_ID` is a default environment variable available to every step. The
Terraform framework stamps it as `RunId`, and the inventory requires that
exact tag value. Step 0 fails before target work unless the selector is non-empty and resolves the
complete three-system topology.

For a local run, resolve the active deployment through the commit tag and export its run id:

```bash
commit_sha="$(git rev-parse HEAD)"
mapfile -t matching_run_ids < <(
  aws ec2 describe-instances \
    --filters \
      "Name=tag:Repository,Values=nwarila-platform/secure-wazuh" \
      "Name=tag:CommitSha,Values=${commit_sha}" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].Tags[?Key=='RunId'].Value[]" \
    --output text |
    tr '\t' '\n' |
    sed '/^$/d' |
    sort -u
)
if [[ "${#matching_run_ids[@]}" -ne 1 ]]; then
  echo "Expected one active deployment for ${commit_sha}; found ${#matching_run_ids[@]}" >&2
  exit 1
fi
export GITHUB_RUN_ID="${matching_run_ids[0]}"
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

The uniqueness check is deliberate: if the same commit has multiple active deployments, choose
the intended workflow run explicitly instead of letting one deployment satisfy another's run.

### Two-phase usage (the cumulative 4/4 proof)

Run the same command a second time after `terraform apply -var refresh_serial=1` replaces the AIO's OS disk. The agents are untouched by the swap and reconnect on their own; the stack reinstalls onto its re-attached data disk; the FIM section fires two more events and then proves **all four** cumulative ledger entries — the two pre-swap survivors and the two new ones — because the ledger lives on the data disk the swap never touches. This is what [`aws-deploy.yml`](../../.github/workflows/aws-deploy.yml) automates for eligible same-repository merge requests and manual dispatches.

The second command starts `ansible-playbook` anew and performs the same three fresh
artifact-reader role assumptions and signatures at their read boundaries. No fact, session, or
URL is cached across the OS swap.

## Verification

The playbook gates itself during the run (it fails the play rather than leaving a half-configured stack), but confirm the headline signals afterward:

- **Indexer cluster is green or yellow.** The play asserts this before Filebeat starts. A single-node AIO box reports green once shards allocate.
- **Dashboard answers on 443.** A TLS-validated login smoke test runs at the end of the role
  against `127.0.0.1`, validating the distinct dashboard listener certificate. If the
  self-signed dev placeholder is used, it is trusted only when its exact configured SHA-256
  fingerprint matches; an issued replacement must chain through the target's normal CA store.
- **The manager indexer connector initializes.** The role requires a fresh post-start success
  record proving that the manager's own connector authenticated, connected, and initialized its
  `wazuh-states-*` index path. Filebeat's separate output test cannot satisfy this gate.
- **Agents enrolled.** Each endpoint in the all-agent `wazuh_agents` group should show as active;
  `wazuh_agents_linux` and `wazuh_agents_windows` classify those endpoints for the platform FIM
  trigger stages. The local manager also runs agent `000` for on-box FIM.
- **File integrity monitoring emits events.** The playbook's own proof section already asserts this end to end, per agent, and fails the run if any ledger entry is missing its alert. Its `PROVEN:` summary names the linux/windows split.

[Run 30316886760](https://github.com/nwarila-platform/secure-wazuh/actions/runs/30316886760)
completed both phases with a green cluster, the dashboard serving its configured listener
certificate on 443, the marked `rbac.db` recovery rung, and realtime FIM readiness in each phase.

## Verification: idempotency

Immediately rerun the playbook. A healthy second run reports `changed=0` for everything **except**
the rotate-every-run credential path (including guarded manager RBAC recovery) and the FIM trigger,
which writes a new uniquely named marker by design. Investigate any other unexpected `changed`
count before promotion.

## Related

- [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md) — the supported topology and inventory groups.
- [`reference/s3-artifacts.md`](../reference/s3-artifacts.md) — the objects this deploy reads and the SHA pins.
- [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md) — why credentials never enter the target shell.
- [`explanation/architecture.md`](../explanation/architecture.md) — what the collapsed AIO stack contains.
