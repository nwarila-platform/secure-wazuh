# Documentation

This directory follows the [Diátaxis](https://diataxis.fr) framework, adopted org-wide by [ADR-0002](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0002-adopt-diataxis-documentation-framework.md). Each document lives in exactly one quadrant.

`secure-wazuh` delivers a STIG- and FIPS-hardened Wazuh 4.14.5 all-in-one SIEM (indexer/OpenSearch + manager + Filebeat + dashboard, plus endpoint agents) onto RHEL/Rocky 8 from a single commit-to-`main` GitOps repo: Terraform provisions the VMs (Proxmox is the permanent live instance, AWS is an ephemeral proof-of-concept) and Ansible configures the stack. Documentation for both halves lives here.

| Quadrant | Purpose | When to read |
|---|---|---|
| [Tutorials](tutorials/) | Learn by doing | "Walk me through a first deploy end to end." |
| [How-to](how-to/) | Solve a specific problem | "How do I rotate the indexer cert PEMs?" |
| [Reference](reference/) | Look up facts | "Which S3 keys does the agent role read?" |
| [Explanation](explanation/) | Understand the rationale | "Why is the bootstrap venv not the default interpreter?" |
| [Decision records](decision-records/) | See what was decided and why | "Why the deny-all `.gitignore` strategy?" |

## Tutorials

_None yet — the end-to-end first deploy currently lives in [How-to → Deploy the stack](how-to/deploy-the-stack.md)._

## How to

- [Deploy the stack](how-to/deploy-the-stack.md) — provision the disk, bootstrap the venv, and run the all-in-one deploy end to end.
- [Provide AWS credentials safely](how-to/provide-aws-credentials-safely.md) — get short-lived S3 creds into the runner env without leaking them.

## Reference

- [Inventory and topology](reference/inventory-and-topology.md) — the inventory groups, the collapsed all-in-one, and the endpoint agent groups.
- [S3 artifacts](reference/s3-artifacts.md) — the bundle, agent RPM/MSI, and cert objects each role reads, and their SHA-256 pins.

## Explanation

- [Architecture](explanation/architecture.md) — what the stack deploys and why the central roles collapsed into one all-in-one role.
- [Composition model](explanation/composition-model.md) — how the framework loader and shared roles are composed in at run time from the pinned `ansible-framework`.
- [RHEL 8 toolchain](explanation/toolchain-rhel8.md) — why ansible-core is pinned to 2.16 and the bootstrap venv is not the default interpreter.

## Architecture decisions

ADRs governing this repository live in this `docs/` tree at [`decision-records/`](decision-records/), split into three scopes per [ADR-0001](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0001-use-architecture-decision-records.md):

- [`decision-records/org/`](decision-records/org/) — byte-identical mirror of the org-baseline ADRs whose master copies live in [`nwarila-platform/.github/docs/decision-records/`](https://github.com/nwarila-platform/.github/tree/main/docs/decision-records).
- [`decision-records/template/`](decision-records/template/) — inherited framework decisions shared across derived Terraform + Ansible product-delivery repositories.
- [`decision-records/repo/`](decision-records/repo/) — repository-specific ADRs:
  - [0001 — Secrets and TLS](decision-records/repo/0001-secrets-and-tls.md)
  - [0002 — Combined Terraform + Ansible delivery](decision-records/repo/0002-combined-terraform-ansible-delivery.md)
  - [0003 — Deny-all explicit `.gitignore`](decision-records/repo/0003-deny-all-explicit-gitignore.md)

ADRs sit at `decision-records/` rather than under one of the four Diátaxis quadrants because they're a separately-governed artifact type (per ADR-0001), not Reference / How-to / Explanation prose.

## Adding a document

1. Decide which quadrant the document belongs to. The four-quadrant test is in ADR-0002 §"Decision Outcome."
2. Create the file under the matching subdirectory.
3. Add a one-line entry in the corresponding section above.
4. If the document is a composite (runbook, troubleshooting guide), label its sections with `## Reference`, `## How to ...`, `## Why ...` per ADR-0002 §"Decision Outcome."
5. Placement is enforced by `tools/check_docs_layout.py`: every Markdown file must live in one of the quadrant subtrees, ADRs must live under `decision-records/org|template|repo/`, and `docs/README.md` is the only Markdown file allowed at the docs root.
