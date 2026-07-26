# ADR-0004: Runtime-Derived AWS Account ID for the S3 Artifact Bucket

| Field          | Value                                                   |
| -------------- | ------------------------------------------------------- |
| Status         | Accepted (amended 2026-07-26)                           |
| Date           | 2026-07-22 (accepted 2026-07-23)                        |
| Authors        | Smarter > Harder (@NWarila)                             |
| Decision-maker | Smarter > Harder (sole portfolio maintainer)            |
| Consulted      | None (sole maintainer)                                  |
| Informed       | None.                                                   |
| Reversibility  | Cheap                                                   |
| Review-by      | N/A (Accepted)                                          |

> **Status note.** Accepted 2026-07-23. The 2026-07-26 amendment below replaces the
> caller-identity delivery mechanism while preserving the decision's security boundary.

## Amendment — 2026-07-26: consume the workflow's existing bucket export

The security decision is unchanged: no real account id or account-shaped bucket value is
committed, and the tracked `<account-id>` value remains an invalid tripwire. The delivery
mechanism is amended:

- Both GitHub workflows already receive the org-global `AWS_ACCOUNT_ID` input and derive the
  artifact bucket alongside their other run targets. They now export that existing value as
  `ANSIBLE_S3_BUCKET`.
- Local operators make one equivalent non-secret export naming the artifact bucket before
  running the unchanged zero-`--extra-vars` playbook command.
- The `wazuh_server` and normal mixed-platform `wazuh_agent` role override sites both read
  `lookup('ansible.builtin.env', 'ANSIBLE_S3_BUCKET')`.
- The controller-side `amazon.aws.aws_caller_info` tasks and the runtime STS identity dependency
  are removed. There is no fallback: role validation rejects an empty bucket and the committed
  tripwire before artifact download.

This reuses a value the workflows already computed instead of asking STS to rediscover it during
Ansible execution. It also makes cross-account artifact access explicit: the supplied bucket may
intentionally differ from the credential-owning account. Redaction remains mandatory because the
bucket is still account-shaped.

The remainder of this ADR records the original caller-identity design and its rationale. Where it
describes caller-identity derivation as the active mechanism, this amendment governs.

## TL;DR

The Wazuh offline artifacts live in an account-scoped S3 bucket named `<account-id>-ansible`
([`s3-artifacts.md`](../../reference/s3-artifacts.md)), but the **real 12-digit account id must never
be committed** ([ADR-0003](0003-deny-all-explicit-gitignore.md); a rotated key and an account id have
both leaked before). Today the env overlays carry a literal `<account-id>` / `CHANGE_ME` placeholder
and **nothing substitutes it** — an unmodified `-e env=int` run uses the literal string and fails at
download; the documented fix is a manual operator edit of a committed file, which is itself incoherent
with "never commit the id."

**Decision:** *derive* the account id at deploy time from the AWS **caller identity** the deploy
already holds (controller-side, `amazon.aws.aws_caller_info` via `delegate_to: localhost`), inject it
through the **existing per-role override-dict channel** as a *fallback default*
(`wazuh_server.s3.bucket | default(_aws_account_id ~ '-ansible')`), and keep the committed overlay
literal as a loud **fail-fast tripwire**. The id is then never stored — committed **or** on disk — the
mechanism is uniform across the Proxmox and AWS targets, and no role loader changes.

## Context and Problem Statement

`s3.bucket` is pinned per environment in each role overlay
([`wazuh_server/vars/redhat_dev.yml`](../../../ansible/applications/wazuh_server/vars/redhat_dev.yml),
agent equivalents) as `<account-id>-ansible`. The account id is treated as don't-commit-sensitive
(ADR-0003's deny-all; `provide-aws-credentials-safely.md` records a real key leak that drove the
policy). The committed record explicitly states the id "is never committed to this repo"
(`redhat_dev.yml` header) and the IAM policies wildcard it (`*-ansible`, `arn:aws:iam::*:role/*wazuh*`).

The gap: **no automated substitution exists.** CI passes only `-e env=... -e wazuh_admin_password=...`
([`deploy.yml`](../../../.github/workflows/deploy.yml)); the documented mechanism is manual
("filled in by the operator") or a playbook override dict ([`s3-artifacts.md:15`](../../reference/s3-artifacts.md)).
An untracked run therefore fails, and the "edit the tracked overlay" instruction for test/prod
(`redhat_test.yml`/`redhat_prod.yml` `CHANGE_ME-ansible-test`) tells the operator to place the real id
into a *tracked* file — which ADR-0003's deny-all does not protect (it guards new untracked files, not
edits to already-tracked ones). There is also a pre-existing three-way contradiction in the record
about the bucket shape: int is `<account-id>-ansible` (not env-suffixed), test/prod are
`CHANGE_ME-ansible-test`/`-prod` (env-suffixed), and `deploy.yml`'s comment asserts the test env uses
the SAME non-env-suffixed bucket — while the instance-profile IAM matches only `*-ansible` and would
*deny* an `<x>-ansible-test` bucket.

## Decision Drivers

- Committed files carry **no real account id** (hard line, ADR-0003 + leak precedents).
- **No manual per-clone/per-run edit**, and no leak boundary crossed (leak boundary = *tracked files*).
- **Topology-uniform**: one mechanism must serve both delivery targets driven from one commit
  ([ADR-0002](0002-combined-terraform-ansible-delivery.md)) — the AWS target *and* the Proxmox target,
  which has AWS *reachability* (it downloads from S3) but no AWS *identity* (no IMDS/instance profile).
- Valid on **both AWS auth paths**: CI OIDC role-assumption and the local boxed-`-admin`-creds path.
- **Least new machinery**; no role loader change (avoids the ratified loader-change gate).
- Consistent with ADR-0001's grain: **derive material the run can produce itself** rather than store
  and distribute it.

## Considered Options

1. **S1 — runtime-derive from caller identity.** Derive the account id from the deploy's own AWS
   identity; inject via the override-dict channel; overlays keep the tripwire literal.
2. **S2 — env-var / `.env` lookup.** Overlay/dict reads `lookup('env', ...)`; operator/CI sets it.
3. **S3 — Terraform output → extra-var.** A `terraform output` supplies the bucket/account id.
4. **S4 — CI extra-var from a secret / parameter store.** CI passes `-e s3_bucket=...`.
5. **S5 — Ansible-Vault an encrypted overlay** committed in-repo, decrypted at deploy.
6. **Dissolve — rename the bucket** off the account-id pattern (nothing to substitute).

## Decision Outcome

**Chosen: S1 — runtime-derive from caller identity, controller-side, via the override-dict fallback
channel.** A record-consistency pass and a code-feasibility pass over the same options converged on S1.

Shape:
- **Derive controller-side**: an `amazon.aws.aws_caller_info` (or `aws sts get-caller-identity`) task
  with `delegate_to: 'localhost'`, mirroring the *only* existing delegation site (the Windows-agent
  MSI download, `wazuh_agent/tasks/present_windows.yml:54`). Controller-side is correct because Ansible
  templates module args on the controller regardless of where the S3 fetch runs, and because it is
  topology-invariant (Proxmox has no AWS identity to query). Use the plain identity fields — **not**
  `account_alias` (that touches `iam:ListAccountAliases`, which *is* deniable; `GetCallerIdentity`
  needs no IAM grant and cannot be denied).
- **Inject via the override-dict channel** already proven for `admin_password`
  ([`deploy-aws-poc.yml`](../../../ansible/playbooks/deploy-aws-poc.yml) per-stage `vars:`; recursive
  `combine` in the role loader overrides only `s3.bucket` without clobbering the SHA pins), shaped as a
  **fallback default** so an explicit hand-set bucket still wins:
  `wazuh_server.s3.bucket: "{{ _aws_account_id }}-ansible"` supplied only when not overridden.
- **Keep the committed overlay literal** `<account-id>-ansible` as a fail-fast tripwire (rewrite the
  header from "operator fills in" to "runtime-substituted; literal is a tripwire").

Why not the others: **S5 is precluded** — a vault overlay is a committed file containing the real id
as recoverable ciphertext (against the "runtime substitution only" bar and the recorded exactly-one-
operator-secret economy; zero vault precedent in the repo). **S3 is infeasible as scoped** — the
Terraform framework exposes no account/bucket output (verified) and is AWS-only, so it cannot serve the
Proxmox leg. **S2/S4 are channels, not sources** — alone they relocate the manual step (fail "no manual
edit"); the GitHub-`vars.*` flavor of S4 converges with S2 and has precedent, but still needs a stored
copy and a second mechanism for the local path. **Dissolve** is rejected on the recorded account-scoped
bucket convention (the IAM `*-ansible` wildcard would tolerate it, but the org convention would not).

## Consequences

**Positive.** The account id is never stored (committed or on disk); can't leak from a tracked file or
go stale; one mechanism for both targets and both auth paths; self-configures the account-scoped-per-env
bucket convention; matches the deliberately account-agnostic IAM; no loader change.

**Operational requirements:**
1. **Fix the leak-once-real diagnostic.** `wazuh_server/tasks/present_redhat.yml:234-245`'s rescue block
   prints `config.s3.bucket` with `no_log: false` justified as "contains no secrets" — true *only* while
   the bucket is a placeholder. Once it resolves to a real derived value this becomes the exact
   "account-id in CLI error text" exposure this repo has already suffered. Redact or reframe it. (Only
   `wazuh_server` has this; the agent role's S3 task is `no_log: true`.)
2. **Document the runtime STS dependency** in [`aws-iam/README.md`](../../reference/aws-iam/README.md)
   (the "authoritative record of the live IAM"): `sts:GetCallerIdentity` is now a runtime API dependency
   (no grant required, not deniable); do not use `account_alias`.
3. **Install `boto3`/`botocore` on the CI controller** for the delegated account lookup and
   Windows-agent S3 path.
4. **Normalize the three-way bucket-shape contradiction** across the development overlay,
   `redhat_test.yml`/`redhat_prod.yml`, and the `deploy.yml` comment — the operative convention is
   account-scoped (`*-ansible`), which S1 makes automatic.
5. **Keep** the SHA-256 pins + object keys committed unchanged (PR-reviewed supply-chain tamper anchors;
   only `s3.bucket` becomes derived) and **keep** the `s3-artifacts.md:15` dict-override sentence as the
   deliberate **cross-account escape hatch**.

**Negative / risks.** Cross-account edge: if the deploy runs under credentials whose account differs
from the bucket's, S1 derives the wrong bucket and fails at download — mitigated by the fallback shape
(an explicit override wins) and by fixing the diagnostic (requirement #1). Adds one controller-side
AWS call. Cross-account deployments therefore require the explicit bucket override.

**Decommission.** RETIRE the `<account-id>`/manual-fill placeholder convention (tripwire semantics
retained); rewrite `s3-artifacts.md` "Bucket naming" to the derivation rule; add an account-id-resolution
piece to `provide-aws-credentials-safely.md`. MERGE (keep) the override sentence as the escape hatch.
KEEP the SHA-pin `CHANGE_ME` values (load-bearing).

## Verification status

**Static only.** Produced and reviewed with the live infrastructure torn down, so the sole verification
authority (a real `ansible-playbook` run ending in a successful S3 download) is **`unknown:
not-run-against-live`**. Ratify, then verify on the next live deploy before marking implemented.
