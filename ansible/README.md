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
│   └── deploy-aws-poc.yml             THE only playbook. Mint credential → data disk → venv →
│                                      AIO stack → Linux agents → Windows OpenSSH bootstrap →
│                                      Windows agents → FIM trigger + cumulative proof.
│                                      Zero --extra-vars; every input is a literal in this file
│                                      or a compose: fact in the inventory above.
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
history if a per-stage entry point is ever needed again.

`wazuh_agent` and `linux_disk_manager` are **not vendored here** — their source of truth is
[`ansible-framework/applications/`](../docs/explanation/composition-model.md) and they are
composed in at run time against the pin in `.github/.framework-pin`. Only `wazuh_server` (the
product-specific central role) is carried in this repo.

Each role's `tasks/main.yml` is the platform's generic loader and is intended to remain
byte-identical across product and framework copies. It validates `ENV`, merges role defaults with
`vars/<family>[_<env>].yml` overlays and the playbook's `<role>:` override dict, and dispatches to
`<state>_<family>.yml` via `first_found`. The tracked `wazuh_server` loader is byte-identical to
the framework application loaders. The Linux roles ship `present_redhat.yml` +
`clean_redhat.yml`; `wazuh_agent` also ships a native Windows entry (`tasks/main_windows.yml` +
`present_windows.yml`) that bypasses the Linux-only loader. **Do not make role-specific edits in
`tasks/main.yml`.**

## Required Ansible vars

**None are supplied by the operator — `deploy-aws-poc.yml` takes zero `--extra-vars`.** The table
below is what the roles consume and where each value comes from.

| var | purpose |
|---|---|
| `ENV` | Environment selector (`int`/`test`/`prod`); the loader auto-loads `vars/redhat_<env>.yml` (Linux) / `vars/windows_<env>.yml` (Windows). Declared **literally as `'int'`** in each play that runs a loader — this playbook targets exactly one environment. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Read from the runner env by the per-play credential bridge in `deploy-aws-poc.yml` and passed to `amazon.aws.s3_object` as module args. |
| `AWS_DEFAULT_REGION` | Region for the S3 download (unless the overlay sets `s3.region`). Resolves `AWS_REGION` first, then `AWS_DEFAULT_REGION`. |
| `AWS_SESSION_TOKEN` | Optional (STS). |
| `wazuh_admin_password` | The one Wazuh credential. **Minted per run** by the playbook's Step 0; the `WAZUH_ADMIN_PASSWORD` env var remains a lower-precedence fallback leg of the role's chain. |

Two more values are runtime-derived rather than declared: the S3 bucket (`<account-id>-ansible`,
from `sts:GetCallerIdentity` — ADR-0004) and the EBS volume's `/dev/disk/by-id` name (from its
`Function` tag, via `linux_disk_manager`'s own AWS resolver).

`WAZUH_ENV` is a separate, CI-side knob: `inventory/aws/aws_ec2.yml` reads it for its
`tag:Environment` discovery filter (default `poc`). It selects which hosts are found, not which
role overlay is loaded.

Credentials are **never exported into the target shell** — the roles pass them as `no_log`
module args so sudo/audit/Wazuh logs never capture them. See
[`../docs/how-to/provide-aws-credentials-safely.md`](../docs/how-to/provide-aws-credentials-safely.md).

## Target prerequisites

- **Central hosts** need the `/mnt/data` data disk (`linux_disk_manager` provisions it — the
  playbook's data-disk play, before any Wazuh stage).
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

The Linux and Windows endpoint groups may individually be empty, but at least one endpoint agent
is required. An AIO-only inventory is unsupported: no trigger host means the loop-driven ledger
file is never created, and the proof play deliberately fails when it slurps that missing file.
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
