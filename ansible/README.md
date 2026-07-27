# Wazuh Ansible

Deploys a STIG- and FIPS-hardened Wazuh 4.14.5 all-in-one SIEM onto RHEL/Rocky 8, plus
Linux and Windows endpoint agents. The central stack (indexer + manager + Filebeat +
dashboard) is **one role on one host** (`wazuh_server`). S3 is the source of truth for the
offline bundle, the cert PEMs, and the per-version agent RPM/MSI — each verified against a
SHA-256 pin after download. See [`../docs/explanation/architecture.md`](../docs/explanation/architecture.md).

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
│   └── deploy-aws-poc.yml             THE only playbook. Propagate run inputs → dispatch each OS
│                                      bootstrap → data disk + AIO → both agents through one
│                                      normal role entry → FIM trigger + cumulative proof.
│                                      Zero --extra-vars; inputs come from this file, inventory,
│                                      and the controller environment.
├── applications/
│   ├── wazuh_server/                  vendored: collapsed all-in-one central role
│   ├── wazuh_agent/                   composed from ansible-framework (Linux RPM + Windows MSI)
│   └── linux_disk_manager/            composed from ansible-framework (step-0 storage)
└── requirements.yml                   ansible.posix · community.general · amazon.aws · ansible.windows
```

The AWS target is **two files**: `inventory/aws/aws_ec2.yml` + `playbooks/deploy-aws-poc.yml`. The
per-component and wrapper playbooks that used to sit alongside it (`site.yml`, `deploy_all.yml`,
`bootstrap.yml`, `linux_disk_manager.yml`, the standalone role playbooks, the FIM triggers, the
pipeline smoke test, `aws_runner_env.yml`) were folded into that one file; they remain in git
history if an individual stage is ever needed again.

The dynamic inventory puts every endpoint in `wazuh_agents`, then also classifies it in exactly
one platform subset: `wazuh_agents_linux` or `wazuh_agents_windows`.

`wazuh_agent` and `linux_disk_manager` are **not vendored here** — their source of truth is
[`ansible-framework/applications/`](../docs/explanation/composition-model.md) and they are
composed in at run time against the pin in `.github/.framework-pin`. Only `wazuh_server` (the
product-specific central role) is carried in this repo.

Each role's `tasks/main.yml` is the platform's generic loader and is intended to remain
byte-identical across product and framework copies. It validates `ENV`, merges role defaults with
`vars/<family>[_<env>].yml` overlays and the playbook's `<role>:` override dict, and dispatches to
`<state>_<family>.yml` via `first_found`. The tracked `wazuh_server` loader is byte-identical to
the framework application loaders. The Linux roles ship `present_redhat.yml` +
`clean_redhat.yml`; `wazuh_agent` also ships `present_windows.yml`, reached through the same
Windows-safe normal loader entry as Linux. **Do not make role-specific edits in
`tasks/main.yml`.**

## Required Ansible vars

**None are supplied as `--extra-vars`.** The table below lists what inventory and roles consume
and where each value comes from.

| var | purpose |
|---|---|
| `ENV` | Environment selector (`dev`/`test`/`prod`); the loader auto-loads `vars/redhat_<env>.yml` (Linux) / `vars/windows_<env>.yml` (Windows). Propagated **literally as `'dev'`** to every host — this playbook targets exactly one environment. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Read from the runner env by the run-input propagation play in `deploy-aws-poc.yml` and passed to `amazon.aws` modules as arguments. |
| `AWS_DEFAULT_REGION` | Region for the S3 download (unless the overlay sets `s3.region`). Resolves `AWS_REGION` first, then `AWS_DEFAULT_REGION`. |
| `AWS_SESSION_TOKEN` | Optional (STS). |
| `ANSIBLE_S3_BUCKET` | Required controller environment variable naming the artifact bucket. GitHub workflows derive it from the org-global account-id input; local operators export it explicitly. |
| `GITHUB_RUN_ID` | Required inventory selector. GitHub provides it to every workflow step; local operators resolve it from the deployed commit-sha tag as documented below. |
| `wazuh_admin_password` | The one Wazuh credential. Each playbook invocation mints a strong 32-character value when `WAZUH_ADMIN_PASSWORD` is absent or empty; a non-empty value remains an explicit override. Normal GitHub runs leave it unset, and the manager role converges from prior `rbac.db` state through its guarded authentication ladder. |

The EBS volume's `/dev/disk/by-id` name is runtime-derived from its `Function` tag through
`linux_disk_manager`'s AWS resolver.

Credentials are **never exported into the target shell** — the roles pass them as `no_log`
module args so sudo/audit/Wazuh logs never capture them. See
[`../docs/how-to/provide-aws-credentials-safely.md`](../docs/how-to/provide-aws-credentials-safely.md).

## Target prerequisites

- **Central hosts** need the `/mnt/data` data disk (`linux_disk_manager` provisions it before the
  `wazuh_server` role entry in Stage 1).
- **boto3/botocore come from the bootstrap venv**, not dnf/pip on the target: the playbook's
  Linux Bootstrap section builds `/opt/ansible/venv` (Python 3.12) and the S3 tasks borrow it via
  a block-level `ansible_python_interpreter` override. The Windows path runs `s3_object` delegated
  to the **controller** venv instead (a Windows target has no boto3). See
  [`../docs/explanation/toolchain-rhel8.md`](../docs/explanation/toolchain-rhel8.md).
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

## Idempotency

Every role is idempotent: a clean run followed by the same playbook (no revert) reports
`changed=0`. Patterns relied on: rotate-every-run write-only ops (keystores, securityadmin),
`overwrite: different` on `s3_object` + explicit SHA-256 verification, `creates:` guards on
extraction, marker-owned managed regions (FIM stanzas), and `changed_when: false` on probes.

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
