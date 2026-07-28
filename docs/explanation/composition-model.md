# Composition model

**Type**: Explanation (Diátaxis). For the deploy that runs inside the composed tree, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md); for the stack it configures, see [`explanation/architecture.md`](architecture.md).

secure-wazuh is the org's canonical exemplar of a **combined delivery repo**: it provisions infrastructure with Terraform and configures it with Ansible, from one repository, driven by commit-to-main GitOps. The AWS path is active; the Proxmox job is parked. The repository carries almost none of the machinery it runs on. Both the Ansible loader and the Terraform resource logic are **composed in from pinned frameworks** at run time. This document explains that model and why it is built this way.

## What this repo actually contains

The repo carries only the product-specific delta:

- **Ansible product role** — `wazuh_server` under `ansible/applications/`, plus the playbooks and inventory that wire it together.
- **Terraform data, not code** — `terraform/proxmox.tfvars` and `terraform/aws.tfvars`. There are **no `.tf` files** in this repo. Variable declarations and resource logic live in the pinned frameworks.

Everything else — the generic role loader, shared roles like `linux_disk_manager` and `wazuh_agent`, and every Terraform resource — belongs to a framework and is pulled in when a run happens.

## The Ansible composition

The product roles resolve fully only when they sit **inside** the framework's directory layout, next to the generic `tasks/main.yml` loader and the shared roles they call. The composition assembles that tree:

1. Read the framework pin at `.github/.framework-pin` — a single commit SHA; see that file for the exact value currently pinned.
2. Lay down `ansible-framework` at that exact commit (this already includes `wazuh_agent` and `linux_disk_manager`).
3. Overlay this repo's `ansible/applications/*` on top, so `wazuh_server` joins the framework's loader and shared roles.
4. Run Ansible from inside the resulting tree.

Locally an operator can reproduce the workflow's checkout-and-overlay steps in the ignored
`_dev-build/` folder. This repository does not ship a compose helper. CI performs the composition
inside its execution container; a local tree matches CI only when it uses the same pinned checkout
and overlay steps.

Because `linux_disk_manager` and `wazuh_agent` are framework-owned and composed in, they are present in the working tree at run time but are **not** deliverables of this repo. The allowlist guard in the `Makefile` excludes the `linux_disk_manager/` and `wazuh_agent/` paths for exactly this reason: it patrols the deliverable trees and would otherwise flag a framework-owned role as an un-allowlisted file.

## The Terraform composition

Terraform here is data-only. Each target is a `*.tfvars` file consumed by a pinned framework that owns the `.tf`:

| Target | Data file | Framework |
|---|---|---|
| Proxmox (permanent) | `terraform/proxmox.tfvars` | `proxmox-vm-terraform-framework` |
| AWS (ephemeral) | `terraform/aws.tfvars` | `aws-terraform-framework` |

CI runs each framework with `-var-file=<target>.tfvars`. The repo supplies the *what* (VM sizes, disks, network, tags); the framework supplies the *how* (providers, resources, variable declarations, validation).

## Two targets, one repo

The repository retains data for two targets with opposite intended lifecycles:

- **Proxmox is the intended permanent instance.** Its workflow job is currently parked with
  `if: false`, and no playbook drives it.
- **AWS is an active ephemeral proof-of-concept.** Applicable pushes run deploy, prove, then
  destroy.

The inventories use the same central group names, and the target data remains separate. The active
Ansible layer currently runs only against AWS; restoring Proxmox requires reconnecting its
playbook path.

## Why compose instead of vendor

Pinning to framework commits rather than copying the loader and resource code into this repo means:

- **One source of truth per capability.** The loader, the shared storage role, and the Terraform resource logic are maintained once in their frameworks and consumed by many product repos. Fixes land in one place.
- **Explicit, reviewable version movement.** Upgrading the framework is a single visible change to `.github/.framework-pin` (or the Terraform framework ref), not a sprawling copy-paste diff. A pin is a hash, so a run is reproducible.
- **A small, honest deliverable surface.** The repo's committed files are only the product-specific delta. The deny-all allowlist `.gitignore` enforces that intent — only explicitly allowlisted deliverable files are tracked — and the `make allowlist-check` guard fails loudly if a deliverable file was added without being allowlisted.

## Consequences

- **Do not run Ansible from the repo root.** The roles only resolve inside the composed tree; run from `_dev-build/` locally or let CI compose.
- **Do not add `.tf` files.** Resource logic belongs in the frameworks; this repo contributes `*.tfvars` only.
- **Framework upgrades are deliberate.** Bumping `.github/.framework-pin` re-points the loader and shared roles; review it as the version change it is.

## Related

- [`explanation/architecture.md`](architecture.md) — the product this composition delivers.
- [`explanation/toolchain-rhel8.md`](toolchain-rhel8.md) — the toolchain the composed tree runs on.
- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — deploying from the composed tree.
