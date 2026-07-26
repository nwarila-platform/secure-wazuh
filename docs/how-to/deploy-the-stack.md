# How to deploy the Wazuh all-in-one stack

**Type**: How-to (Diátaxis). For topology facts see [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md); for the artifacts this pulls from S3 see [`reference/s3-artifacts.md`](../reference/s3-artifacts.md); for credential handling see [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md); for why the run happens inside a composed tree see [`explanation/composition-model.md`](../explanation/composition-model.md).

This guide takes a freshly applied AWS proof-of-concept environment and brings up the collapsed Wazuh all-in-one (AIO) stack — OpenSearch indexer, manager, Filebeat, and dashboard on one host — plus both endpoint agent platforms, and then proves a real File Integrity Monitoring event on each.

The AWS target is **exactly two committed files**: the dynamic inventory `ansible/inventory/aws/aws_ec2.yml` and the single playbook `ansible/playbooks/deploy-aws-poc.yml`. There is no `group_vars/` directory and no second playbook — every connection fact lives in the inventory's `compose:` block and every deployment input is a literal in the playbook's own play `vars:`.

The permanent Proxmox target is **parked**: its job in [`deploy.yml`](../../.github/workflows/deploy.yml) is gated off and no playbook currently drives it. `ansible/inventory/proxmox.yml` is still committed as the inventory that target will use again.

## Prerequisites

- **A controller with the pinned toolchain.** Install the development dependencies from `requirements-dev.txt`: `ansible-core >=2.16,<2.17`, `ansible-lint 24.x`, `yamllint`. The runtime collections (`ansible.posix <2`, `community.general <8`, `amazon.aws`, `ansible.windows`) come from `ansible/requirements.yml`. The version ceiling is deliberate — see [`explanation/toolchain-rhel8.md`](../explanation/toolchain-rhel8.md).
- **A composed run tree.** The product roles under `ansible/applications/` resolve fully only when overlaid onto the pinned `ansible-framework` loader. CI composes this automatically; for local runs, build the `_dev-build/` tree with the dev compose helper and run every Ansible command from inside it. See [`explanation/composition-model.md`](../explanation/composition-model.md).
- **`boto3`/`botocore` on the controller.** The dynamic inventory plugin and the playbook's controller-delegated calls (the ADR-0004 account-id derive, the Windows MSI fetch, `linux_disk_manager`'s EBS Function-tag resolver) all run `amazon.aws` modules under the controller's own interpreter.
- **The SSM Session Manager plugin on the controller.** The PoC security group has zero inbound rules, so every SSH/SFTP/SCP call is tunnelled through `aws ssm start-session`; that ProxyCommand shells out to a separate binary the AWS CLI does not bundle.
- **Artifacts staged in S3.** Upload the `wazuh-offline.tar.gz` bundle and record its SHA-256 in `s3.bundle_sha256`; upload the node cert PEMs under `s3.certs_prefix`; upload the agent RPM/MSI and record their SHA pins. Object names and pins are catalogued in [`reference/s3-artifacts.md`](../reference/s3-artifacts.md). The bucket itself is never committed — the playbook derives `<account-id>-ansible` at run time (ADR-0004).
- **AWS credentials in the runner environment** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` or `AWS_DEFAULT_REGION`, optional `AWS_SESSION_TOKEN`). Each play that invokes an `amazon.aws` module reads them with `lookup('ansible.builtin.env', ...)` in its own `vars:` and passes them as `no_log` module arguments. Never export them into the target shell — see [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md).
- **No operator secret.** This target needs none: the playbook's Step 0 mints the OpenSearch/dashboard `admin` password for the run, and every other credential is generated fresh and never persisted.

## Procedure: deploy

Everything below runs from inside the composed tree.

```bash
# Static gates.
PYTHONUTF8=1 yamllint .
ansible-lint

# Syntax and inventory resolution.
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml --syntax-check
ansible-inventory -i inventory/aws/aws_ec2.yml --graph

# Deploy + prove, in one command. No --extra-vars, ever.
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

That one playbook runs, in order: mint the run's ephemeral admin password; provision and mount the `/mnt/data` data disk (`linux_disk_manager`, selecting the EBS volume by its `Function` tag and mounting by filesystem UUID); build `/opt/ansible/venv` on every Linux target; deploy the AIO `wazuh_server` role onto `wazuh_servers`; enroll `wazuh_agent` on `wazuh_agents` (Linux); flip the Windows OpenSSH `DefaultShell` from `cmd` to PowerShell; enroll `wazuh_agent` on `wazuh_agents_windows` via its native Windows entry point; then fire one real FIM event per agent platform, append them to the cumulative ledger on `/mnt/data`, and assert every ledger entry reached the `wazuh-alerts-*` index attributed to the endpoint agent (`agent.id != 000`).

The Linux and Windows endpoint groups may individually be empty, but at least one endpoint agent is required. An AIO-only inventory is unsupported: without a trigger host the loop-driven ledger file is never created, and the proof play deliberately fails when it slurps that missing file.

### Environment selection

`ENV: 'int'` is declared literally in each play that runs a role loader — this playbook targets exactly one environment, so there is nothing to parameterize. The `WAZUH_ENV` environment variable is a different knob: the inventory plugin reads it for its `tag:Environment` filter (default `poc`), i.e. it selects which hosts are discovered, not which `vars/redhat_<env>.yml` overlay a role loads.

### Two-phase usage (the cumulative 4/4 proof)

Run the same command a second time after `terraform apply -var refresh_serial=1` replaces the AIO's OS disk. The agents are untouched by the swap and reconnect on their own; the stack reinstalls onto its re-attached data disk; the FIM section fires two more events and then proves **all four** cumulative ledger entries — the two pre-swap survivors and the two new ones — because the ledger lives on the data disk the swap never touches. This is what [`e2e-full.yml`](../../.github/workflows/e2e-full.yml) automates per merge request.

## Verification

The playbook gates itself during the run (it fails the play rather than leaving a half-configured stack), but confirm the headline signals afterward:

- **Indexer cluster is green or yellow.** The play asserts this before Filebeat starts. A single-node AIO box reports green once shards allocate.
- **Dashboard answers on 443.** A TLS-validated login smoke test runs at the end of the role against `127.0.0.1` (always in the node cert SANs).
- **Agents enrolled.** Each endpoint in `wazuh_agents` / `wazuh_agents_windows` should show as active; the local manager also runs agent `000` for on-box FIM.
- **File integrity monitoring emits events.** The playbook's own proof section already asserts this end to end, per agent, and fails the run if any ledger entry is missing its alert. Its `PROVEN:` summary names the linux/windows split.

## Verification: idempotency

Immediately rerun the playbook. A healthy second run reports `changed=0` for everything **except** the rotate-every-run credential tasks (fresh secrets each run, nothing persisted) and the FIM trigger, which writes a new uniquely-named marker by design. Treat any other unexpected `changed` count as a review item before promotion.

## Related

- [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md) — the supported topology and inventory groups.
- [`reference/s3-artifacts.md`](../reference/s3-artifacts.md) — the objects this deploy reads and the SHA pins.
- [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md) — why credentials never enter the target shell.
- [`explanation/architecture.md`](../explanation/architecture.md) — what the collapsed AIO stack contains.
