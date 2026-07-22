# Architecture Decision Records

This directory holds the Architecture Decision Records (ADRs) governing this repository, split into three scopes per [ADR-0001](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0001-use-architecture-decision-records.md):

- [`org/`](org/) — byte-identical mirror of the org-baseline ADRs whose master copies live in [`nwarila-platform/.github`](https://github.com/nwarila-platform/.github/tree/main/docs/decision-records). These apply across the organization and travel with every adopting repo.
- [`template/`](template/) — inherited framework decisions that apply across derived repositories (the combined Terraform + Ansible product-delivery baseline).
- [`repo/`](repo/) — repository-specific ADRs that apply only to `secure-wazuh`. Independent numbering namespace from the org mirror (`org/0001` and `repo/0001` can coexist).

The MADR 4.0-aligned format and lifecycle rules are the same across all scopes; see [ADR-0001 §"Decision Outcome"](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0001-use-architecture-decision-records.md) for details.

## Index

### Org-mirrored

None mirrored into this repo yet. Org-baseline ADRs are synced down from [`nwarila-platform/.github/docs/decision-records/`](https://github.com/nwarila-platform/.github/tree/main/docs/decision-records) as they are adopted; each lands at `org/NNNN-...md` with a row added below.

| #  | Title | Status | Date | Summary |
|----|-------|--------|------|---------|
| _none yet_ | | | | |

### Template-mirrored

None mirrored yet. Inherited framework decisions land at `template/NNNN-...md` with a row added below.

| #  | Title | Status | Date | Summary |
|----|-------|--------|------|---------|
| _none yet_ | | | | |

### Repository-specific

| #  | Title | Status | Date | Summary |
|----|-------|--------|------|---------|
| [0001](repo/0001-secrets-and-tls.md) | Two-Tier PKI and a Rotate-Every-Run Secrets Model | Accepted (partially implemented — secrets landed, PKI pending) | 2026-07-21 | One operator password; internal service creds rotate every run; target two-tier PKI (on-target internal CA + S3 dashboard cert). |
| [0002](repo/0002-combined-terraform-ansible-delivery.md) | Combined Terraform-Provisions + Ansible-Configures Product Delivery | Accepted | 2026-07-21 | One repo provisions (Terraform) and configures (Ansible) the product; commit-to-`main` GitOps loop. |
| [0003](repo/0003-deny-all-explicit-gitignore.md) | Deny-All Explicit `.gitignore` for secure-wazuh | Accepted | 2026-07-21 | `.gitignore` starts with `**`; every tracked path is re-included with an explicit `!/path`; enforced by `make allowlist-check`. |

## Authoring rules

- **Org-baseline ADRs are mirrors only.** Do not edit files under `org/` in this repository directly. The master copies live in [`nwarila-platform/.github/docs/decision-records/`](https://github.com/nwarila-platform/.github/tree/main/docs/decision-records). Amendments are PR'd in the org repo and synced down here.
- **Repo-specific ADRs go under `repo/`.** Follow the [ADR-0001 §"Decision Outcome"](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0001-use-architecture-decision-records.md) numbering and template rules. The `repo/` namespace is independent of `org/` (`org/0001` and `repo/0001` can coexist).
- **Updating this index** is the same PR as adding the new ADR.
