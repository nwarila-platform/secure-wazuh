# How to deploy the Wazuh all-in-one stack

**Type**: How-to (Diátaxis). For topology facts see [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md); for the artifacts this pulls from S3 see [`reference/s3-artifacts.md`](../reference/s3-artifacts.md); for credential handling see [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md); for why the run happens inside a composed tree see [`explanation/composition-model.md`](../explanation/composition-model.md).

This guide takes a reachable, STIG-hardened RHEL/Rocky 8 host and brings up the collapsed Wazuh all-in-one (AIO) stack — OpenSearch indexer, manager, Filebeat, and dashboard on one host — plus any endpoint agents. The same procedure drives both delivery targets: the permanent Proxmox instance and the ephemeral AWS proof-of-concept. Only the inventory and `-var-file` differ.

## Prerequisites

- **A controller with the pinned toolchain.** Install the development dependencies from `requirements-dev.txt`: `ansible-core >=2.16,<2.17`, `ansible-lint 24.x`, `yamllint`. The runtime collections (`ansible.posix <2`, `community.general <8`, `amazon.aws`, `ansible.windows`) come from `ansible/requirements.yml`. The version ceiling is deliberate — see [`explanation/toolchain-rhel8.md`](../explanation/toolchain-rhel8.md).
- **A composed run tree.** The product roles under `ansible/applications/` resolve fully only when overlaid onto the pinned `ansible-framework` loader. CI composes this automatically; for local runs, build the `_dev-build/` tree with the dev compose helper and run every Ansible command from inside it. See [`explanation/composition-model.md`](../explanation/composition-model.md).
- **The data volume mounted at `/mnt/data`.** The stack stores all component data under `/mnt/data/wazuh` via bind mounts. It does **not** partition, format, or mount raw disks — provision that first with the step-0 `linux_disk_manager` play, which selects the disk by stable WWN and mounts by UUID.
- **Artifacts staged in S3.** Upload the `wazuh-offline.tar.gz` bundle and record its SHA-256 in `s3.bundle_sha256`; upload the node cert PEMs under `s3.certs_prefix`; if deploying agents, upload the standalone agent RPM and record `s3.agent_rpm_sha256`. Object names and pins are catalogued in [`reference/s3-artifacts.md`](../reference/s3-artifacts.md).
- **AWS credentials in the runner environment** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, optional `AWS_SESSION_TOKEN`). These are read by `playbooks/aws_runner_env.yml` and passed straight to the S3 module as `no_log` arguments. Never export them into the target shell — see [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md).
- **The `env` slug** (`int`, `test`, or `prod`) and the **one operator secret**, the OpenSearch/dashboard `admin` password. Every other credential is generated fresh on each run and never persisted.

## Procedure: mount the data volume (step 0)

Run this once per fresh host, before the stack. It is idempotent on subsequent runs.

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/linux_disk_manager.yml -e env=int
```

The play mounts the persistent Wazuh data disk at `/mnt/data` with STIG-friendly options (`nodev,nosuid`, but not `noexec` — the indexer stages and runs content there). Confirm the mount before continuing:

```bash
ansible -i inventory/proxmox.yml wazuh_servers -b -m command -a 'findmnt /mnt/data'
```

## Procedure: set the operator secret and env

The site playbook takes exactly one password, passed as an extra-var. If it is omitted, a
lab default (`WazuhLab-Admin-2026!`) applies — replace that default before using retained
production data or real users.

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml \
  -e env=int -e wazuh_admin_password="${WAZUH_ADMIN_PASSWORD}"
```

CI ([`deploy.yml`](../../.github/workflows/deploy.yml)) supplies it the same way, from a
`WAZUH_ADMIN_PASSWORD` secret. `site.yml` reads it as:

```yaml
wazuh_server:
  secrets:
    admin_password: "{{ wazuh_admin_password | default('WazuhLab-Admin-2026!') }}"
```

The manager API users (`wazuh`, `wazuh-wui`) are derived deterministically from this password, so they stay re-authenticatable across reruns without anything being written to disk.

## Procedure: lint, then deploy

Run these from inside the composed tree.

```bash
# Static gates.
PYTHONUTF8=1 yamllint .
ansible-lint

# Syntax and reachability.
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml --syntax-check -e env=int
ansible -i inventory/proxmox.yml all -m ping

# Deploy: bootstrap venv -> AIO stack -> agents.
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml -e env=int
```

`site.yml` runs four stages: it imports `bootstrap.yml` to build `/opt/ansible/venv` (Python 3.12 with modern boto3 for the S3 tasks), deploys the AIO `wazuh_server` role onto the `wazuh_servers` group, deploys `wazuh_agent` onto any hosts in `wazuh_agents` (Linux), then deploys `wazuh_agent` — via its native Windows entry point, which bypasses the Linux-only loader — onto any hosts in `wazuh_agents_windows`. Any empty group is a no-op, so the same playbook covers AIO-only, +Linux-agent, and +Windows-agent topologies unchanged.

`playbooks/deploy_all.yml` wraps the step-0 `linux_disk_manager` play together with this same sequence (disk → venv → central → Linux agents → Windows agents) as the single end-to-end entry point:

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/deploy_all.yml -e env=int
```

To deploy against the ephemeral AWS target instead, point at the AWS inventory and keep the rest of the flow identical. The Terraform layer that stands the host up is data-only; the resource logic lives in the pinned frameworks (see [`explanation/composition-model.md`](../explanation/composition-model.md)).

## Verification

The role gates itself during the run (it will fail the play rather than leave a half-configured stack), but confirm the headline signals afterward:

- **Indexer cluster is green or yellow.** The play asserts this before Filebeat starts. A single-node AIO box reports green once shards allocate.
- **Dashboard answers on 443.** A TLS-validated login smoke test runs at the end of the role against `127.0.0.1` (always in the node cert SANs).
- **Agents enrolled.** Each endpoint in `wazuh_agents` should show as active; the local manager also runs agent `000` for on-box FIM.
- **File integrity monitoring emits events.** The role owns a realtime (inotify) `<syscheck>` stanza on `/etc`, `/usr/bin`, `/usr/sbin`. Touching a watched file should index an alert.

Optionally run the alert-path smoke test, which appends one synthetic alert and waits for it to appear in `wazuh-alerts-*`:

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/wazuh_pipeline_smoke.yml
```

## Verification: idempotency

Immediately rerun the site playbook. A healthy second run reports `changed=0` for everything **except** the rotate-every-run credential tasks, which always report `changed` by design (fresh secrets each run, nothing persisted). Treat any other unexpected `changed` count as a review item before promotion.

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml -e env=int
```

## Related

- [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md) — the supported topology and inventory groups.
- [`reference/s3-artifacts.md`](../reference/s3-artifacts.md) — the objects this deploy reads and the SHA pins.
- [`how-to/provide-aws-credentials-safely.md`](provide-aws-credentials-safely.md) — why credentials never enter the target shell.
- [`explanation/architecture.md`](../explanation/architecture.md) — what the collapsed AIO stack contains.
