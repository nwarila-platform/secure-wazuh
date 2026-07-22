# secure-wazuh

> STIG- and FIPS-hardened **Wazuh 4.14.5** SIEM, delivered end-to-end from one repository:
> **Terraform provisions, Ansible configures, GitOps drives it** — a permanent Proxmox
> instance and an ephemeral AWS proof-of-concept, both from a single commit to `main`.

[![CI](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/ci.yml/badge.svg)](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/ci.yml)
[![Security](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/security.yaml/badge.svg)](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/security.yaml)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://pre-commit.com/)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Project Structure](#project-structure)
- [Deployment — the GitOps loop](#deployment--the-gitops-loop)
- [Developer Workflow](#developer-workflow)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Overview

`secure-wazuh` is the reference implementation for a **combined Terraform + Ansible
product-delivery** repository in the nwarila-platform org. It stands up a complete,
hardened Wazuh all-in-one SIEM — OpenSearch indexer, manager, Filebeat, and dashboard on
a single node — and keeps two environments in lockstep from the same source of truth:

| Target | Lifecycle | On every commit to `main` |
|---|---|---|
| **Proxmox** | Permanent, live | Redeploy **in place** |
| **AWS** | Ephemeral PoC | Deploy → **test** → **destroy** |

The repo is deliberately thin: it owns the **product roles** and the **per-target data**,
and composes the reusable logic in at run time. Resource logic lives in the pinned
Terraform frameworks; the generic Ansible loader and shared roles live in the pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework). See
[docs/explanation/composition-model.md](docs/explanation/composition-model.md).

## Features

| Area | What you get |
|---|---|
| **Hardening** | STIG-aligned RHEL/Rocky 8 baseline + FIPS mode; least-privilege services |
| **All-in-one** | Indexer + manager + Filebeat + dashboard on one node (fail-fast on unsupported multi-node) |
| **File Integrity Monitoring** | Realtime (inotify) FIM that emits change **events** with **zero audit records** (`whodata="no"`) |
| **Secrets** | Operator supplies **one** password (the dashboard admin); everything else is generated/derived, **rotated every run, nothing persisted** |
| **TLS** | OpenSearch/Filebeat/dashboard TLS from SHA-256-verified S3 cert PEMs today; a two-tier on-target PKI is the **tracked target** (see [ADR&nbsp;0001](docs/decision-records/repo/0001-secrets-and-tls.md), which carries its implementation-status banner) |
| **Supply chain** | Offline package bundle + pinned SHA256; deny-all explicit `.gitignore`; org security workflows (CodeQL, Scorecard, IaC scan) |
| **Reproducibility** | Pinned `ansible-framework` commit (`.github/.framework-pin`); pinned RHEL-8 ansible-core 2.16 toolchain |

## Prerequisites

- A Linux control host (WSL Ubuntu on Windows) with the dev toolchain: `make install`.
- The persistent data volume provisioned at `/mnt/data` (handled by the framework's
  `linux_disk_manager` role — disk selected by stable WWN, mounted by UUID).
- The Wazuh **offline bundle** and the **dashboard public cert** uploaded to S3 (keys in
  [docs/reference/s3-artifacts.md](docs/reference/s3-artifacts.md)).
- AWS credentials supplied to the runner **only** as module args — never exported into the
  target shell (Wazuh logs sudo argv). See
  [docs/how-to/provide-aws-credentials-safely.md](docs/how-to/provide-aws-credentials-safely.md).

## Getting Started

```bash
# 1. Install the dev toolchain (RHEL-8 pinned: ansible-core 2.16, ansible-lint 24.x) + git hooks
make install

# 2. Static gates (what CI runs): lint + terraform fmt + the allowlist guard
make ci

# 3. Deploy to a target (composes the pinned ansible-framework, then runs the stack).
#    The dev compose helper builds a local _dev-build/ mirror of the CI execution container.
#    (compose scripts are dev-only and intentionally untracked; see the composition model doc.)
cd _dev-build && ansible-playbook -i inventory/proxmox.yml playbooks/deploy_all.yml \
  -e env=int -e @/path/to/aws-vars.json
```

Full walkthrough: [docs/how-to/deploy-the-stack.md](docs/how-to/deploy-the-stack.md).

## Project Structure

```text
secure-wazuh/
├── ansible/
│   ├── applications/
│   │   ├── wazuh_server/       # collapsed all-in-one role (indexer+manager+filebeat+dashboard)
│   │   └── wazuh_agent/        # endpoint agent role (composed from ansible-framework)
│   ├── playbooks/              # site.yml + per-component playbooks
│   └── inventory/
├── terraform/
│   ├── proxmox.tfvars          # permanent target inputs  (proxmox-vm-terraform-framework)
│   └── aws.tfvars              # ephemeral PoC inputs      (aws-terraform-framework)
├── docs/                       # Diátaxis: tutorials / how-to / reference / explanation / ADRs
├── .github/
│   ├── workflows/              # ci · release-please · security · deploy (the GitOps loop)
│   └── .framework-pin          # exact ansible-framework commit CI composes against
├── .gitignore                  # deny-all EXPLICIT allowlist (only ** is a glob)
├── Makefile                    # install · lint · ci · allowlist-check · clean
└── mkdocs.yml
```

> **Deny-all allowlist.** `.gitignore` ignores everything and re-includes only explicitly
> named paths — no glob but the leading `**`. A stray secret or scratch file can never be
> swept into a commit; a new deliverable file must be deliberately allowlisted (CI's
> `allowlist-check` guards the footgun). See
> [ADR&nbsp;0003](docs/decision-records/repo/0003-deny-all-explicit-gitignore.md).

## Deployment — the GitOps loop

A push to `main` triggers [`deploy.yml`](.github/workflows/deploy.yml):

1. **Proxmox job** — `terraform apply -var-file=proxmox.tfvars` against the pinned Proxmox
   framework (in place, never destroyed), then composes and runs the Ansible stack.
2. **AWS job** — `terraform apply -var-file=aws.tfvars` against the pinned AWS framework,
   composes and runs the stack, **tests** it (cluster green + dashboard 200 + a real
   FIM-event proof), then **`terraform destroy`** (`always()`) to tear the PoC down.

Rationale and the full pattern: [ADR&nbsp;0002](docs/decision-records/repo/0002-combined-terraform-ansible-delivery.md).

> **Status.** [`deploy.yml`](.github/workflows/deploy.yml) is a reviewed **first cut** — the job
> graph, guardrails, and framework pinning are in place, but the per-environment secret/OIDC
> wiring (marked with `# WIRE:` in the workflow) must be completed before it runs green end to end.

## Developer Workflow

- **Branch + PR.** `main` is protected; commits follow
  [Conventional Commits](https://www.conventionalcommits.org) (scope = role name or
  `framework`), enforced by `pre-commit` and release automation.
- **Compose model.** Product roles resolve only inside the composed tree. The dev helper
  builds `_dev-build/` (framework@`.framework-pin` + this repo's roles overlaid) — an
  on-disk mirror of the CI execution container. Both are git-ignored.
- **`make` targets.** `make lint`, `make ci`, `make allowlist-check`, `make pre-commit`.

## Documentation

Docs follow [Diátaxis](https://diataxis.fr/). Start at [docs/README.md](docs/README.md):
how-to guides, reference, architecture explanations, and the Architecture Decision Records.

## Contributing

Contribution and commit conventions are inherited org-wide — see
[nwarila-platform/.github/CONTRIBUTING.md](https://github.com/nwarila-platform/.github/blob/main/CONTRIBUTING.md).

## Security

Report vulnerabilities per the org policy:
[nwarila-platform/.github/SECURITY.md](https://github.com/nwarila-platform/.github/blob/main/SECURITY.md).
The repo's own secrets-and-TLS posture is documented in
[ADR&nbsp;0001](docs/decision-records/repo/0001-secrets-and-tls.md).

## License

[MIT](LICENSE) © Smarter > Harder
