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
│   └── proxmox.yml                    production all-in-one inventory
├── playbooks/
│   ├── deploy_all.yml                 ONE playbook, whole environment (disk → stack → agents)
│   ├── bootstrap.yml                  builds /opt/ansible/venv (imported first by the stack plays)
│   ├── linux_disk_manager.yml         step 0: provision + mount the /mnt/data data disk
│   ├── site.yml                       central stack → Linux agents → Windows agents
│   ├── wazuh_server.yml               standalone all-in-one central stack
│   ├── wazuh_agent.yml                standalone Linux endpoint agents
│   ├── wazuh_agent_windows.yml        standalone Windows endpoint agents (native win_* path)
│   ├── wazuh_trigger_fim.yml          fire + prove a real Linux agent FIM event
│   ├── wazuh_trigger_fim_windows.yml  fire + prove a real Windows agent FIM event
│   ├── wazuh_pipeline_smoke.yml       optional alert-INDEXING smoke test
│   └── aws_runner_env.yml             maps AWS_* runner env vars into module args
├── applications/
│   ├── wazuh_server/                  vendored: collapsed all-in-one central role
│   ├── wazuh_agent/                   composed from ansible-framework (Linux RPM + Windows MSI)
│   └── linux_disk_manager/            composed from ansible-framework (step-0 storage)
└── requirements.yml                   ansible.posix · community.general · amazon.aws · ansible.windows
```

`wazuh_agent` and `linux_disk_manager` are **not vendored here** — their source of truth is
[`ansible-framework/applications/`](../docs/explanation/composition-model.md) and they are
composed in at run time against the pin in `.github/.framework-pin`. Only `wazuh_server` (the
product-specific central role) is carried in this repo.

Each role's loader (`tasks/main.yml`) is the platform's generic, byte-identical loader. It
validates `ENV`, merges role defaults with `vars/<family>[_<env>].yml` overlays and the
playbook's `<role>:` override dict, and dispatches to `<state>_<family>.yml` via `first_found`.
The Linux roles ship `present_redhat.yml` + `clean_redhat.yml`; `wazuh_agent` also ships a
native Windows entry (`tasks/main_windows.yml` + `present_windows.yml`) that bypasses the
Linux-only loader. **Do not edit `tasks/main.yml` per role.**

## Required Ansible vars

| var | purpose |
|---|---|
| `env` | Environment selector (`int`/`test`/`prod`); the loader auto-loads `vars/redhat_<env>.yml` (Linux) / `vars/windows_<env>.yml` (Windows). |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Read from the runner env by `aws_runner_env.yml` and passed to `amazon.aws.s3_object` as module args. |
| `AWS_DEFAULT_REGION` | Region for the S3 download (unless the overlay sets `s3.region`). |
| `AWS_SESSION_TOKEN` | Optional (STS). |
| `wazuh_admin_password` | Optional override for the one operator password (CI passes it; a lab default applies otherwise). |

Credentials are **never exported into the target shell** — the roles pass them as `no_log`
module args so sudo/audit/Wazuh logs never capture them. See
[`../docs/how-to/provide-aws-credentials-safely.md`](../docs/how-to/provide-aws-credentials-safely.md).

## Target prerequisites

- **Central hosts** need the `/mnt/data` data disk (`linux_disk_manager` provisions it — step 0).
- **boto3/botocore come from the bootstrap venv**, not dnf/pip on the target: `bootstrap.yml`
  builds `/opt/ansible/venv` (Python 3.12) and the S3 tasks borrow it via a task-level
  `ansible_python_interpreter` override. The Windows path runs `s3_object` delegated to the
  **controller** venv instead (a Windows target has no boto3). See
  [`../docs/explanation/toolchain-rhel8.md`](../docs/explanation/toolchain-rhel8.md).
- **Endpoint hosts** run only the agent role and do not need `/mnt/data`.

## Running it

```bash
# Whole environment in one playbook (disk → venv → central → Linux agents → Windows agents):
ansible-playbook -i inventory/proxmox.yml playbooks/deploy_all.yml -e env=int -e @<aws-vars>.json

# Or a single component:
ansible-playbook -i inventory/proxmox.yml playbooks/wazuh_server.yml        -e env=int -e @<aws-vars>.json
ansible-playbook -i inventory/proxmox.yml playbooks/wazuh_agent.yml         -e env=int -e @<aws-vars>.json
ansible-playbook -i <win-inventory>       playbooks/wazuh_agent_windows.yml -e env=int
```

Any empty inventory group is a no-op, so `deploy_all.yml` covers AIO-only, +Linux-agent, and
+Windows-agent topologies unchanged.

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
