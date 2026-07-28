# secure-wazuh

> STIG- and FIPS-hardened **Wazuh 4.14.5** SIEM, delivered end-to-end from one repository:
> **Terraform provisions, Ansible configures, GitOps drives it** — an active ephemeral AWS
> proof-of-concept, with the permanent Proxmox target currently parked.

[![CI](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/ci.yml/badge.svg)](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/ci.yml)
[![Security](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/security.yaml/badge.svg)](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/security.yaml)
[![e2e-full](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/e2e-full.yml/badge.svg)](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/e2e-full.yml)
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
- [Proof of Concept — live evidence](#proof-of-concept--live-evidence)
- [Developer Workflow](#developer-workflow)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Overview

`secure-wazuh` is the reference implementation for a **combined Terraform + Ansible
product-delivery** repository in the nwarila-platform org. Its active AWS path stands up a
complete, hardened Wazuh all-in-one SIEM — OpenSearch indexer, manager, Filebeat, and dashboard on
a single node — from the same source that retains the parked Proxmox target data:

| Target | Lifecycle | Current state |
|---|---|---|
| **Proxmox** | Intended permanent target | Parked; the workflow job is gated off and no playbook drives it |
| **AWS** | Ephemeral PoC | Applicable pushes deploy → **prove** → **destroy** |

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
| **Secrets** | Each playbook invocation resolves one dashboard-admin password, normally minting it; service credentials rotate per run, while guarded recovery converges persistent manager RBAC state |
| **TLS** | Rotate-every-run internal PKI minted only on the target; it never transits S3, whose only certificate material is the dashboard listener pair and sidecars (see [ADR&nbsp;0001](docs/decision-records/repo/0001-secrets-and-tls.md)) |
| **Supply chain** | Offline package bundle + pinned SHA256; deny-all explicit `.gitignore`; org security workflows (CodeQL, Scorecard, IaC scan) |
| **Reproducibility** | Pinned `ansible-framework` commit (`.github/.framework-pin`); pinned RHEL-8 ansible-core 2.16 toolchain |

## Prerequisites

- A Linux control host (WSL Ubuntu on Windows) with the dev toolchain: `make install`.
- The persistent data volume provisioned at `/mnt/data` (handled by the framework's
  `linux_disk_manager` role — disk selected by stable WWN, mounted by UUID).
- The Wazuh **offline bundle**, **dashboard listener pair + digest sidecars**, and standalone
  **agent RPM/MSI** uploaded to S3 (keys in
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

# 3. Deploy to the AWS PoC (composes the pinned ansible-framework, then runs the stack and
#    proves a real FIM event on each endpoint). Zero --extra-vars: the whole target is two
#    files — the dynamic inventory and the one playbook.
#    Reproduce the workflow's pinned checkout and overlay in an ignored local _dev-build/ tree.
#    This repository does not ship a compose helper; see the composition model doc.
cd _dev-build && ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

Full walkthrough: [docs/how-to/deploy-the-stack.md](docs/how-to/deploy-the-stack.md).

## Project Structure

```text
secure-wazuh/
├── ansible/
│   ├── applications/
│   │   ├── wazuh_server/       # collapsed all-in-one role (indexer+manager+filebeat+dashboard)
│   │   └── wazuh_agent/        # endpoint agent role (composed from ansible-framework)
│   ├── playbooks/              # deploy-aws-poc.yml — the one playbook, end to end
│   └── inventory/              # aws/aws_ec2.yml (dynamic) · proxmox.yml (parked target)
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

An applicable push to `main`, or a manual dispatch, triggers
[`deploy.yml`](.github/workflows/deploy.yml):

1. **Proxmox job** — skipped by its `if: false` gate. The target data remains committed, but no
   playbook currently drives it.
2. **AWS job** — `terraform apply -var-file=aws.tfvars` against the pinned AWS framework,
   composes and runs the stack, **tests** it (cluster-health gate + TLS-validated dashboard
   response + a real FIM-event proof), then **`terraform destroy`** (`always()`) to tear the PoC
   down.

Rationale and the full pattern: [ADR&nbsp;0002](docs/decision-records/repo/0002-combined-terraform-ansible-delivery.md).

[`deploy.yml`](.github/workflows/deploy.yml) derives its AWS role and state-bucket names from
organization-scoped configuration, authenticates with OIDC, composes the pinned AWS and Ansible frameworks,
and destroys the ephemeral AWS stack after proof.

## Proof of Concept — live evidence

Eligible same-repository merge requests self-prove against real AWS:
[`e2e-full.yml`](.github/workflows/e2e-full.yml)
deploys the full 3-system PoC (AIO + a Linux agent + a Windows agent), fires a real File Integrity
Monitoring event on **both** endpoint platforms, force-replaces the AIO's OS drive mid-run
(`terraform apply -var refresh_serial=1`) to prove agents reconnect and indexer data survives a
manager rebuild, validates all four cumulative events, then **always** destroys the environment —
a disposable, genuinely-exercised deploy rather than a mocked test. For same-repository MRs touching
the workflow's configured `paths:`, it fires on open, reopen, or the draft→ready transition; apply the
`rerun-poc` label for an on-demand re-run. Cost is
roughly $1 per run and $0 standing. Results land straight in the MR as
[`docs/reference/poc-evidence.md`](docs/reference/poc-evidence.md); full logs are in the
[`e2e-full`](https://github.com/nwarila-platform/secure-wazuh/actions/workflows/e2e-full.yml)
Actions workflow.

## Developer Workflow

- **Branch + PR.** Commits follow
  [Conventional Commits](https://www.conventionalcommits.org) (scope = role name or
  `framework`), enforced by `pre-commit` and release automation. Branch-protection state is an
  external repository setting and is not asserted here.
- **Compose model.** Product roles resolve only inside the composed tree. A local operator can
  reproduce CI's framework@`.framework-pin` plus product-role overlay in ignored `_dev-build/`;
  this repository does not ship a compose helper.
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
