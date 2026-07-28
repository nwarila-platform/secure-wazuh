# Wazuh Ansible

Deploys a STIG- and FIPS-hardened Wazuh 4.14.5 all-in-one SIEM onto RHEL/Rocky 8, plus
Linux and Windows endpoint agents. The central stack (indexer + manager + Filebeat +
dashboard) is **one role on one host** (`wazuh_server`). S3 is the source of truth for the
offline bundle, the dashboard listener pair, and the per-version agent RPM/MSI. The internal PKI
is minted on the AIO target every run and never transits S3. The dashboard listener pair and its
sidecars are the only certificate material S3 holds. See
[`../docs/explanation/architecture.md`](../docs/explanation/architecture.md).

## Layout

```text
ansible/
├── ansible.cfg                        STIG-friendly tmp paths, pipelining, become
├── inventory/
│   ├── aws/
│   │   └── aws_ec2.yml                AWS PoC: amazon.aws.aws_ec2 dynamic inventory. Discovers
│   │                                  hosts by the org Function/Environment auto-tags and sets
│   │                                  EVERY connection fact in its compose: block (SSH-over-SSM
│   │                                  ProxyCommand, user, shell type, interpreter, key path).
│   │                                  Deliberately NO sibling group_vars/ — see its header.
│   └── proxmox.yml                    permanent all-in-one inventory (target currently parked)
├── playbooks/
│   └── deploy-aws-poc.yml             THE only playbook. Resolve run inputs → platform prep →
│                                      data disk + AIO → Linux + Windows agents with adjacent
│                                      controller signing + HTTPS fetches → FIM proof.
│                                      Zero --extra-vars; inputs come from this file, inventory,
│                                      and the controller environment.
├── applications/
│   ├── wazuh_server/                  vendored: collapsed all-in-one central role
│   ├── wazuh_agent/                   framework role with product fetch-task overlays
│   ├── linux_disk_manager/            composed from ansible-framework (step-0 storage)
│   └── s3_artifact_delivery/          composed shared mint/sign/fetch helper role
└── requirements.yml                   ansible.posix · community.general · amazon.aws · ansible.windows
```

The AWS target is **two files**: `inventory/aws/aws_ec2.yml` + `playbooks/deploy-aws-poc.yml`. The
per-component and wrapper playbooks that used to sit alongside it (`site.yml`, `deploy_all.yml`,
`bootstrap.yml`, `linux_disk_manager.yml`, the standalone role playbooks, the FIM triggers, the
pipeline smoke test, `aws_runner_env.yml`) were folded into that one file; they remain in git
history if an individual stage is ever needed again.

The dynamic inventory puts every endpoint in `wazuh_agents`, then also classifies it in exactly
one platform subset: `wazuh_agents_linux` or `wazuh_agents_windows`.

`linux_disk_manager`, the base `wazuh_agent` role, and `s3_artifact_delivery` are composed at run
time from
[`ansible-framework/applications/`](../docs/explanation/composition-model.md) at the pin in
`.github/.framework-pin`. This repository overlays only `wazuh_agent`'s Linux and Windows
installer task files, which consume the shared artifact-delivery role. `wazuh_server` remains
product-specific.

Each lifecycle-managed application role's `tasks/main.yml` is the platform's generic loader and is
intended to remain byte-identical across product and framework copies. It validates `ENV`, merges
role defaults with `vars/<family>[_<env>].yml` overlays and the playbook's `<role>:` override dict,
and dispatches to `<state>_<family>.yml` via `first_found`. The tracked `wazuh_server` loader is
byte-identical to the framework application loaders. The Linux roles ship `present_redhat.yml` +
`clean_redhat.yml`; `wazuh_agent` also ships `present_windows.yml`, reached through the same
Windows-safe normal loader entry as Linux. The one-shot `s3_artifact_delivery` helper has explicit
`tasks_from` entries instead of `tasks/main.yml`. **Do not make role-specific edits in
application loaders.**

## Required Ansible vars

**None are supplied as `--extra-vars`.** The table below lists what inventory and roles consume
and where each value comes from.

| var | purpose |
|---|---|
| `ENV` | Environment selector (`dev`/`test`/`prod`); the loader auto-loads `vars/redhat_<env>.yml` (Linux) / `vars/windows_<env>.yml` (Windows). Propagated **literally as `'dev'`** to every host — this playbook targets exactly one environment. |
| `AWS_DEFAULT_REGION` | Controller region for session assumption, local signing, dashboard-pair retrieval, and the delegated EBS resolver. Resolves `AWS_REGION` first, then `AWS_DEFAULT_REGION`. |
| `ANSIBLE_LOCAL_TEMP` | Absolute controller temp path also used as delegated localhost's `ansible_remote_tmp`. Workflows place it under `runner.temp`, outside the workspace, and clean it after each invocation. |
| `ANSIBLE_S3_BUCKET` | Required controller environment variable naming the artifact bucket. GitHub workflows derive it from the org-global account-id input; local operators export it explicitly. |
| `ARTIFACT_READER_ROLE_ARN` | Required controller environment variable identifying `secure-wazuh-artifact-reader`. The server, Linux agent, and Windows agent read groups each assume it immediately beside their artifact use. |
| `GITHUB_RUN_ID` | Required inventory selector. GitHub provides it to every workflow step; local operators resolve it from the deployed commit-sha tag as documented below. |
| `wazuh_admin_password` | The one Wazuh credential. Each playbook invocation mints a strong 32-character value when `WAZUH_ADMIN_PASSWORD` is absent or empty; a non-empty value remains an explicit override. Normal GitHub runs leave it unset, and the manager role converges from prior `rbac.db` state through its guarded authentication ladder. |

The EBS volume's `/dev/disk/by-id` name is runtime-derived from its `Function` tag through
`linux_disk_manager`'s AWS resolver.

The ambient deploy credential and every scoped artifact-reader session remain on the controller.
Each package fetch attempt gets a fresh session and signature before the target downloads over
HTTPS; the dashboard listener pair gets a separate fresh session and is downloaded and pushed
from the controller. Step 0 fails closed unless the live instance profile has the expected
SSM-only role and no legacy artifact policy. See
[`../docs/how-to/provide-aws-credentials-safely.md`](../docs/how-to/provide-aws-credentials-safely.md).

## Target prerequisites

- **Central hosts** need the `/mnt/data` data disk (`linux_disk_manager` provisions it before the
  `wazuh_server` role entry in Stage 1).
- **No target needs amazon.aws, boto3, botocore, or `/opt/ansible/venv`.** Linux uses
  `ansible.builtin.get_url`; Windows uses `ansible.windows.win_get_url`. The controller alone
  carries the AWS SDK used for inventory, role assumption, signing, dashboard-pair retrieval, and
  the delegated EBS resolver.
- **Endpoint hosts** run only the agent role and do not need `/mnt/data`.

## Running it

```bash
# The whole environment, deployed and PROVEN, in one command. No --extra-vars, ever.
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

Outside GitHub Actions, resolve `GITHUB_RUN_ID` through the deployment's commit-sha tag first; see
[`../docs/how-to/deploy-the-stack.md`](../docs/how-to/deploy-the-stack.md#run-scoped-inventory).

This AWS target requires exactly one AIO, one Linux agent, and one Windows agent. Step 0 asserts
that complete topology before any target work, so an empty, partial, or duplicate run-scoped
inventory fails rather than skipping plays.
Run the playbook a second time after an AIO OS-swap (`terraform apply -var refresh_serial=1`) for
the cumulative FIM proof — see
[`../docs/how-to/deploy-the-stack.md`](../docs/how-to/deploy-the-stack.md).

## Convergence

Stable package, configuration, mount, and probe paths converge without unnecessary changes.
`get_url` checksum enforcement, `creates:` guards on extraction, marker-owned FIM regions, and
`changed_when: false` probes provide that behavior. A repeat playbook run is intentionally not
`changed=0`: fresh internal PKI, rotated credentials and keystores,
`securityadmin`, guarded manager-RBAC convergence, and the FIM proof marker execute per invocation.

## Verification

```bash
PYTHONUTF8=1 yamllint ansible   # or: make yamllint
ansible-lint                    # or: make ansible-lint
```

The product roles resolve fully only inside the composed framework tree; the authoritative
lint runs there (see [`../docs/explanation/composition-model.md`](../docs/explanation/composition-model.md)).
`make ansible-lint` lints what resolves standalone.

## Pointers

- [`../docs/how-to/deploy-the-stack.md`](../docs/how-to/deploy-the-stack.md) — full deploy walkthrough.
- [`../docs/explanation/composition-model.md`](../docs/explanation/composition-model.md) — how framework roles compose in.
- `applications/<role>/defaults/main.yml` — defaults and operator prereqs.
- `applications/wazuh_agent/meta/argument_specs.yml` — the input contract (composed role only; `wazuh_server` does not ship one).
