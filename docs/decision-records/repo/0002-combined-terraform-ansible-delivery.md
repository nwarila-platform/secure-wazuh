# ADR-0002: Combined Terraform-Provisions + Ansible-Configures Product Delivery

| Field          | Value                                        |
| -------------- | -------------------------------------------- |
| Status         | Accepted                                     |
| Date           | 2026-07-21                                   |
| Authors        | Smarter > Harder (@NWarila)                  |
| Decision-maker | Smarter > Harder (sole portfolio maintainer) |
| Consulted      | None.                                        |
| Informed       | None.                                        |
| Reversibility  | Medium                                       |
| Review-by      | N/A (Accepted)                               |

> **Amendment.** `wazuh_agent` has since moved from **vendored** (this repo's
> `ansible/applications/wazuh_agent/`) to **composed in from `ansible-framework`** at run
> time — the same treatment this ADR describes for the generic loader and
> `linux_disk_manager`. Wherever the text below names `wazuh_agent` among the product roles
> that "live in `ansible/applications/`" or are "genuinely this repo's," read that as the
> state at acceptance: `wazuh_server` is now the only vendored product role. See
> [`explanation/composition-model.md`](../../explanation/composition-model.md) for the
> current state.

## TL;DR

`secure-wazuh` is a single **product-delivery** repository that both **provisions**
infrastructure and **configures** it, from one source of truth, driven by a
commit-to-main GitOps loop. Terraform in this repo is **data-only**:
`terraform/proxmox.tfvars` and `terraform/aws.tfvars` with **no `.tf` files** — the
resource logic and variable declarations live in the pinned
`proxmox-vm-terraform-framework` and `aws-terraform-framework`, which CI runs with
`-var-file=<target>.tfvars`. Ansible is **composed**: the product roles
(`wazuh_server`, `wazuh_agent`) live in `ansible/applications/`, and the generic loader
plus shared roles (`linux_disk_manager`) are composed in from the pinned
`ansible-framework` at run time (pin in `.github/.framework-pin`). Two targets are driven
from that one source on every commit to `main`: **Proxmox** is the **permanent** live
instance (each commit redeploys **in place**), and **AWS** is an **ephemeral**
proof-of-concept (each commit runs **deploy → test → destroy**). This repository is the
reusable exemplar for the combined-delivery pattern in `nwarila-platform`.

## Context and Problem Statement

The `nwarila-platform` portfolio already has two well-established repository classes:

- **Framework repositories** — reusable, versioned modules with no target of their own:
  `proxmox-vm-terraform-framework`, `aws-terraform-framework`, `ansible-framework`. A
  consumer pins them and supplies data.
- **Control-plane repositories** — org governance and reusable CI, e.g.
  `nwarila-platform/.github`.

What the portfolio lacked was a canonical **product** repository that shows how to
*compose* those frameworks to ship a real, hardened product — here, a STIG/FIPS Wazuh
4.14.5 all-in-one SIEM — onto real targets. Delivering a product spans two axes that are
usually split across separate repos or teams:

- **Provisioning** the machine (Terraform against Proxmox and AWS), and
- **Configuring** the machine (Ansible: install, harden, wire up the Wazuh stack).

Splitting those two axes across repositories fractures the source of truth: a change that
alters both the VM shape and the configuration that runs on it must span two pull
requests in two repos, and no single commit can atomically represent "the product as it
should be." It also makes it structurally possible for "what was tested" to diverge from
"what is live."

There is a second temptation: to name and structure the repo generically — as a
"runner," a "cluster," or an executor that happens to consume both frameworks — rather
than as the product it delivers. That framing invites unrelated products to accrete into
one repo and hides what the repo actually ships.

This ADR settles the repository shape: one product-delivery repo, data-only Terraform,
composed Ansible, and a commit-to-main loop that stands up two targets from one commit.

## Decision Drivers

1. **One atomic source of truth per product.** A single commit should represent the whole
   product — its infrastructure shape *and* its configuration — so a change to either is
   reviewed and shipped together.
2. **No forked resource logic.** The product should declare *intent* (data) and consume
   versioned framework logic, not copy and drift `.tf` or loader code.
3. **Tested == live, structurally.** Both targets should be built from the same commit so
   the deploy that is proven cannot diverge from the deploy that is permanent.
4. **Cheap, safe iteration.** An ephemeral second target should prove the from-zero path
   on every commit without accruing cost or manual teardown.
5. **Small product surface.** Product roles stay small; the loader and shared roles stay
   byte-identical to their framework source across sibling repos.
6. **Name the product, not the machinery.** The repository's identity should be the thing
   it delivers, so the delivery unit equals the product.

## Considered Options

1. **Two repositories: an infra repo and a config repo.** Terraform in one, Ansible in
   another.
2. **A generic "runner" / "cluster" repo.** Name the repo after the executor and let it
   consume both frameworks generically for any product.
3. **Fold the product into a framework repo.** Add Wazuh-specific delivery into one of the
   existing framework repositories.
4. **One product-delivery repo composing both frameworks (chosen).** Data-only Terraform +
   composed Ansible + commit-to-main GitOps, named for the product.

## Decision Outcome

Chosen option: **Option 4 — one product-delivery repository composing both frameworks.**

### Terraform is data-only

`terraform/` contains `proxmox.tfvars` and `aws.tfvars` and **no `.tf` files**. The
resource logic and variable declarations live in the pinned frameworks. CI runs each
framework with `-var-file=<target>.tfvars`:

- Proxmox provisioning runs `proxmox-vm-terraform-framework` with
  `-var-file=proxmox.tfvars`.
- AWS provisioning runs `aws-terraform-framework` with `-var-file=aws.tfvars`.

The product repo therefore declares *intent* — VM sizing, disks, networking, names — as
data, and consumes the versioned framework's HCL. It never forks resource logic; a
framework upgrade is a pin bump, not a merge.

### Ansible is composed

The product roles that are genuinely this repo's — `wazuh_server`, `wazuh_agent` — live in
`ansible/applications/`. The generic role loader and the shared roles
(`linux_disk_manager`) are **composed in from `ansible-framework` at run time** rather than
vendored. The framework commit is pinned in `.github/.framework-pin` — a single commit SHA;
see that file for the exact value currently pinned. A dev-only, **uncommitted** compose script
builds a local `_dev-build/` tree — copy `ansible-framework@pin`, overlay this repo's
`ansible/applications/*` onto it, then run Ansible from inside the composed tree. CI
performs the same composition inside its execution container. The generated `_dev-build/`
is never tracked (see [ADR-0003](0003-deny-all-explicit-gitignore.md)), so the loader stays
byte-identical to its framework source and the product surface stays small.

### One source, two targets, commit-to-main GitOps

Every commit to `main` drives both targets from the same source:

- **Proxmox — permanent, in place.** The permanent live SIEM is redeployed in place on
  every commit (converge, or revert-to-clean-snapshot then Ansible). This is the instance
  that actually collects alerts.
- **AWS — ephemeral, deploy → test → destroy.** On every commit the AWS target is stood up
  from zero, exercised by the test path, then **destroyed**. This proves the from-scratch
  provisioning path on a second cloud and avoids standing cost.

Because both targets are built from the same commit, "what was tested on AWS" and "what is
live on Proxmox" cannot structurally diverge: they are the same source of truth applied to
two targets.

## Pros and Cons of the Options

### Option 1: Two repositories (infra + config)

- **Good, because** each repo has a single concern and a smaller blast radius.
- **Good, because** infra and config teams could own their repos independently.
- **Bad, because** the product's source of truth is fractured; a change spanning VM shape
  and configuration needs two coordinated PRs.
- **Bad, because** no single commit represents the whole product, so tested-vs-live drift
  becomes possible.
- **Bad, because** the GitOps loop cannot be atomic across the two repos.

### Option 2: Generic "runner" / "cluster" repo

- **Good, because** a generic executor could, in principle, deliver many products.
- **Bad, because** this repo *is* a product (`secure-wazuh`), not a generic executor;
  naming it for the machinery hides what it ships.
- **Bad, because** a generic bucket invites unrelated products to accrete into one repo,
  eroding the delivery-unit-equals-product property.
- **Bad, because** it blurs the framework-versus-consumer boundary the portfolio
  otherwise keeps crisp.

### Option 3: Fold into a framework repo

- **Good, because** it reuses an existing repo and its CI.
- **Bad, because** frameworks are reusable modules with **no target of their own**; a
  product that deploys to real Proxmox and AWS targets is a *consumer*, not a framework.
- **Bad, because** it couples a specific product's delivery to a general-purpose module,
  contaminating the module's reusability.

### Option 4: One product-delivery repo composing both frameworks (chosen)

- **Good, because** one commit atomically represents the whole product — infra and config.
- **Good, because** data-only Terraform and composed Ansible consume versioned framework
  logic instead of forking it; upgrades are pin bumps.
- **Good, because** the two targets are built from the same commit, so tested equals live
  by construction.
- **Good, because** the repository's identity is the product it delivers, keeping the
  delivery unit equal to the product.
- **Neutral, because** it depends on the pinned frameworks being available at their pins;
  that dependency is explicit and Renovate-manageable.
- **Bad, because** contributors must understand the compose step — the roles do not resolve
  fully until the framework is composed in — which is a learning cost paid once.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms. The wording `MUST`,
`SHOULD`, and `MAY` follows [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

1. **Data-only Terraform.** `terraform/` MUST contain only `.tfvars` (and state, which is
   ignored); no `.tf` files MAY exist in this repo. A reviewer SHOULD reject any `.tf`
   file added under `terraform/` or at the repo root.
2. **Framework-driven apply.** Terraform CI MUST invoke the pinned
   `proxmox-vm-terraform-framework` and `aws-terraform-framework` with
   `-var-file=proxmox.tfvars` / `-var-file=aws.tfvars`; it MUST NOT apply local HCL.
3. **Pinned composition.** The Ansible loader and shared roles MUST be composed from
   `ansible-framework` at the commit named in `.github/.framework-pin`; CI MUST compose
   from that pin. The pin MUST be a commit SHA, not a floating ref.
4. **Composition never tracked.** `_dev-build/` MUST NOT be committed; the deny-all
   `.gitignore` and the `allowlist-check` guard enforce this
   (see [ADR-0003](0003-deny-all-explicit-gitignore.md)).
5. **Two targets from one commit.** On push to `main`, the Proxmox job MUST converge the
   permanent instance in place and the AWS job MUST run deploy → test → destroy; both MUST
   consume the same commit.
6. **Product naming.** The repository MUST be named for the product it delivers
   (`secure-wazuh`), not for a generic runner or cluster role.

## Consequences

### Positive

- One commit is the whole product; infra and config are reviewed and shipped together.
- Tested (AWS, from zero) equals live (Proxmox, in place) by construction.
- Framework logic is consumed, not forked; upgrades are pin bumps and the loader stays
  byte-identical to its source.
- The ephemeral AWS target continuously proves the from-scratch path without standing cost.
- The repo is a copyable exemplar: another product adopts the pattern by pinning the
  frameworks, adding its own `applications/` roles, and supplying its two `.tfvars`.

### Negative

- The repo depends on three pinned frameworks; a force-rewrite of a pinned SHA breaks CI
  until the pin is updated.
- Contributors must learn the compose step; roles do not resolve fully standalone, so
  local linting of the product roles alone is partial (see the Makefile `ansible-lint`
  target's note).
- Driving a permanent in-place target from every commit means a bad commit reaches the
  live SIEM through the same loop that reaches the disposable one; the AWS test gate is the
  primary safeguard.

### Neutral

- The two `.tfvars` files are the only Terraform content this repo owns; all HCL lives
  upstream. Terraform state is ignored, not tracked.
- Endpoint agents ride the same Ansible composition as the central roles; the pattern does
  not change for them.
- Framework pin bumps are dependency updates and are expected to flow through the same
  update tooling the rest of the portfolio uses.

## Assumptions

This decision rests on the following assumptions. If any becomes false, this ADR should be
revisited:

1. `proxmox-vm-terraform-framework`, `aws-terraform-framework`, and `ansible-framework`
   remain available at their pinned commits and continue to accept the data this repo
   supplies.
2. The compose approach (framework overlay + product `applications/`) remains the
   portfolio convention for consuming the Ansible framework.
3. Running a permanent in-place target and an ephemeral deploy-test-destroy target from the
   same commit remains the intended delivery model for this product.
4. The AWS test path is a meaningful gate — a green from-zero deploy-and-test on AWS is a
   credible proxy for the in-place Proxmox converge.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

Pending. The implementing change set covers the data-only `terraform/` layout, the
`.github/.framework-pin` composition wiring in CI, the commit-to-main workflows for the
Proxmox in-place and AWS deploy-test-destroy targets, and the `allowlist-check` guard that
keeps `_dev-build/` untracked.

## Related ADRs

- [ADR-0001 (repo)](0001-secrets-and-tls.md) — the secrets and TLS model that this delivery
  loop stands up on both targets; rotate-every-run is only cheap because of this loop.
- [ADR-0003 (repo)](0003-deny-all-explicit-gitignore.md) — the deny-all `.gitignore` that
  keeps the generated `_dev-build/` composition, Terraform state, and `.tfvars` secrets out
  of version control.
- [ADR-0003 (org)](../org/0003-use-deny-all-gitignore-strategy.md) — the org baseline the
  repo-local `.gitignore` ADR adopts.

## Compliance Notes

This ADR establishes a delivery architecture rather than a deployed control. Its value is
in reproducibility and traceability: a single commit deterministically produces both a
tested and a live deployment. The table is illustrative, not exhaustive, and is not a claim
of compliance by adoption alone.

| Framework              | Control / Practice ID                                    | Potential Evidence Contribution                                                                                       |
| ---------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | CM-2 (Baseline Configuration)                            | Data-only `.tfvars` plus pinned frameworks and framework pin define a reproducible infrastructure baseline.          |
| NIST SP 800-53 Rev. 5  | CM-3 (Configuration Change Control)                      | Commit-to-main GitOps makes each infrastructure and configuration change a reviewed, version-controlled commit.      |
| NIST SP 800-53 Rev. 5  | SA-10 (Developer Configuration Management)               | Pinning the consumed frameworks by commit SHA documents the exact provisioning and configuration logic in effect.    |
| NIST SP 800-218 (SSDF) | PO.3 / PW.6 (Define and maintain a secure build; reproducible builds) | Composing from a pinned framework in CI supports a reproducible, auditable build of the deployed product.  |
