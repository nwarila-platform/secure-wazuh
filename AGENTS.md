# Repo guidance for AI assistants

## What this repo is

`secure-wazuh` deploys a STIG- and FIPS-hardened **Wazuh 4.14.5 all-in-one SIEM** (indexer +
manager + Filebeat + dashboard on one host) plus **Linux and Windows endpoint agents**, onto
RHEL/Rocky 8. It is the org's first **combined Terraform-provisions + Ansible-configures**
product-delivery repo (ADR-0002): Terraform provisions the VMs (Proxmox = permanent live, AWS =
ephemeral PoC) and Ansible configures the stack, driven by a commit-to-`main` GitOps loop.

Read the docs first — they are the source of truth and are kept current:
- [`docs/explanation/architecture.md`](docs/explanation/architecture.md) — the collapsed all-in-one and why.
- [`docs/explanation/composition-model.md`](docs/explanation/composition-model.md) — how framework roles compose in.
- [`docs/explanation/toolchain-rhel8.md`](docs/explanation/toolchain-rhel8.md) — the ansible-core 2.16 / bootstrap-venv pin.
- [`docs/reference/inventory-and-topology.md`](docs/reference/inventory-and-topology.md) and [`docs/reference/s3-artifacts.md`](docs/reference/s3-artifacts.md).

## Architecture in one screen

- **Central stack is ONE role, `wazuh_server`**, on ONE host. The historical
  `wazuh_indexer`/`wazuh_dashboard` roles were folded in; split-host topology is gone. Everything
  internal resolves over `127.0.0.1`.
- **Endpoint agents** are the `wazuh_agent` role: `present_redhat.yml` for Linux (RPM), and a
  native Windows path (`tasks/main_windows.yml` + `present_windows.yml`, MSI) that **bypasses the
  Linux-only loader** and is invoked via `include_role: {name: wazuh_agent, tasks_from: main_windows}`.
- **Step 0** is `linux_disk_manager` — provisions/mounts the `/mnt/data` data disk (disk chosen by
  stable WWN, mounted by UUID). The central role assumes `/mnt/data` is already mounted.

## Composition model (important)

`wazuh_agent` and `linux_disk_manager` are **NOT vendored here** — their source of truth is
`ansible-framework/applications/<role>/`, composed into `ansible/applications/` at run time
against the SHA in `.github/.framework-pin`. They are gitignored in this repo (and excluded from
the Makefile allowlist guard). **Edit those two roles in `ansible-framework`, then re-sync the
composed copy.** Only `wazuh_server` (the product-specific central role) is vendored here.
Never edit any role's byte-identical `tasks/main.yml` loader.

## Toolchain

- **ansible-core is pinned `>=2.16,<2.17`.** 2.17+ emits `from __future__ import annotations`,
  which SyntaxErrors on RHEL 8 platform-python 3.6 (the only interpreter carrying the
  libselinux/dnf/firewalld C bindings the roles need). Collections: `ansible.posix<2`,
  `community.general<8`, `amazon.aws`, plus `ansible.windows` for the Windows agent (which
  runs on the controller, so no 3.6 concern).
- **boto3 comes from the bootstrap venv, not the default interpreter.** `bootstrap.yml` builds
  `/opt/ansible/venv` (Python 3.12) and the `amazon.aws.s3_object` tasks borrow it via a
  block-level `ansible_python_interpreter` override; every other task runs under platform-python.
  The Windows path runs `s3_object` delegated to the **controller** venv (a Windows target has no
  boto3) — the runner venv therefore needs boto3 too. `bootstrap.yml` targets
  `all:!wazuh_agents_windows` (it asserts RHEL 8).

## Playbooks

`deploy_all.yml` (disk → venv → central → Linux agents → Windows agents) is the single
end-to-end entry. Components: `bootstrap.yml`, `linux_disk_manager.yml`, `site.yml`,
`wazuh_server.yml`, `wazuh_agent.yml`, `wazuh_agent_windows.yml`. Proof/optional:
`wazuh_trigger_fim.yml` / `wazuh_trigger_fim_windows.yml` (fire + prove a real agent FIM event),
`wazuh_pipeline_smoke.yml` (alert-indexing smoke test).

## Secrets and AWS handoff

- The operator supplies exactly **one** password (`wazuh_server.secrets.admin_password`; CI passes
  `-e wazuh_admin_password`). Everything else is generated fresh each run or derived from it, and
  nothing is persisted. Manager-API users are derived from the admin password so reruns stay
  authenticatable. See [ADR-0001](docs/decision-records/repo/0001-secrets-and-tls.md) (note its
  implementation-status banner — the two-tier PKI is the target, not yet shipped).
- **AWS credentials are read from the runner env** by `aws_runner_env.yml` and passed to
  `s3_object` as `no_log` module args — **never exported into the target shell** (Wazuh logs sudo
  argv). Never print a full 12-digit account id or any credential.

## Lab quickstart (VMware Workstation)

- **tcnhq-waz01c** `192.168.0.186` — central AIO. Snapshots: `pre-ansible-clean-ssh-ready`
  (clean, 16 GB RAM / 60 GB data disk), `wazuh-server-deployed-green`.
- **tcnhq-waz02a** `192.168.0.187` — Linux agent endpoint (cloned from the AIO baseline).
  Snapshot `pre-agent-clean`.
- **Windows Server 2025** `192.168.0.181` — Windows agent endpoint. SSH as `Administrator` with
  `/root/.ssh/windows_server_2025_ed25519`; OpenSSH DefaultShell = PowerShell. Snapshot `pre-agent-clean`.
- Controller is WSL Ubuntu-24.04. Ansible runs from the pipx-managed venv on PATH (ansible-core
  2.16). Lab inventory `lab/inventory.yml`; become password from a gitignored controller-side
  vars file (`-e @<lab-become.json>`).
- **Gotcha:** a VM reverted from a RUNNING/memory snapshot keeps a frozen clock — run
  `chronyc makestep` (Linux) / `w32tm /resync` (Windows) after a raw `vmrun` revert, or S3
  request-signing fails with a misleading "Key does not exist". The `lab/scripts/revert-vm.sh`
  script already does this for waz01c.

## Verification

```bash
make ci   # yamllint + ansible-lint + terraform fmt + allowlist-check + docs-layout
```

The product roles resolve fully only inside the composed framework tree; `make ansible-lint`
lints what resolves standalone (see the composition-model doc).

## Conventions

- **Deny-all explicit `.gitignore`** (ADR-0003): starts with `**`; every deliverable is
  re-included with an explicit `!/path`; `make allowlist-check` fails loudly on a stray file.
- **Diátaxis docs + MADR ADRs** under `docs/`; `tools/check_docs_layout.py` enforces placement.
- **Zero AI attribution** in anything committed. Git author is `NWarila`.
- Playbooks set `gather_facts: false`; the loader gathers facts on first entry. Roles use
  `#region` banners, `no_log` on credential-bearing tasks, and retry-until (never `sleep`) for
  transient states.
