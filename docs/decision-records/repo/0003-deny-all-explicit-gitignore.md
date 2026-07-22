# ADR-0003: Deny-All Explicit `.gitignore` for secure-wazuh

| Field          | Value                                        |
| -------------- | -------------------------------------------- |
| Status         | Accepted                                     |
| Date           | 2026-07-21                                   |
| Authors        | Smarter > Harder (@NWarila)                  |
| Decision-maker | Smarter > Harder (sole portfolio maintainer) |
| Consulted      | None.                                        |
| Informed       | None.                                        |
| Reversibility  | Cheap                                        |
| Review-by      | N/A (Accepted)                               |

> **Amendment.** `wazuh_agent` has since joined `linux_disk_manager` as a framework-owned
> role composed in at run time rather than vendored. Wherever this ADR's allowlist-check
> description names only `linux_disk_manager/` as the guard's framework-owned exclusion
> (the confirmation guard and the assumptions below), read `wazuh_agent/` as excluded for the
> identical reason — the Makefile's `GUARD_EXCLUDE` pattern already covers both paths. See
> [`explanation/composition-model.md`](../../explanation/composition-model.md) for the
> current state.

## TL;DR

`secure-wazuh` uses a **deny-all, explicit-allowlist** `.gitignore`. The first and only
non-comment glob is `**` (ignore everything); every tracked path is then re-included with
an explicit `!`-prefixed allowlist entry. No other wildcard is permitted. This adopts the
org-baseline strategy ([ADR-0003 (org)](../org/0003-use-deny-all-gitignore-strategy.md))
and records the repo-specific stakes and the local enforcement. The stakes are unusually
high here: this is a secret-dense delivery repo that touches Terraform state (plaintext
secrets after `apply`), `.tfvars`, AWS credential material, on-target-minted certificate
keys, and a generated, uncommitted `_dev-build/` composition tree. Because no glob can
sweep any of those in, every committed file is deliberate. The tradeoff is that each new
file needs an allowlist line, guarded by the `allowlist-check` CI target that fails when a
deliverable-area file is not allowlisted.

## Context and Problem Statement

The dominant `.gitignore` convention is **allow-all with explicit denies**: track
everything, then enumerate patterns to skip. Its structural failure mode is that anything
*not* denied is tracked — a new tool, a new artifact type, or a new class of secret file
all default to committed, and `git add .` gives no signal at the moment of failure.

`secure-wazuh` is exactly the kind of repository where that failure mode is dangerous. It
is a combined provision-and-configure delivery repo (see
[ADR-0002](0002-combined-terraform-ansible-delivery.md)), and its working tree routinely
contains high-sensitivity, non-committable content:

- **Terraform state** (`terraform/terraform.tfstate` and timestamped backups), which holds
  decrypted secrets and resource metadata in plaintext after `apply`.
- **`.tfvars` and `.env`** carrying provisioning inputs and, historically, credential-like
  values.
- **AWS credential material** staged for the deploy runner.
- **On-target-minted certificate keys** and generated secrets from the rotate-every-run
  model (see [ADR-0001](0001-secrets-and-tls.md)) that may transit the working tree.
- **`_dev-build/`**, the generated Ansible composition tree (framework@pin overlaid with
  this repo's `applications/*`), which is a build artifact and must never be tracked.
- **Lab and agent scratch** — `*.retry`, `__pycache__/`, editor and agent tooling files.

A single forgotten deny in an allow-all `.gitignore` turns any of these into a committed
secret. The org has already established the deny-all baseline as the default tracking
strategy; this ADR records that `secure-wazuh` adopts it, *why the repo-specific stakes
make it non-negotiable here*, and the local CI guard that catches the one ergonomic failure
mode the strategy introduces.

## Decision Drivers

1. **Default-safe.** A new file must be ignored unless someone deliberately allowlists it.
   The cost of one allowlist line is negligible; the cost of one committed `tfstate` or
   credential is a compromise.
2. **No glob can sweep a secret.** With `**` as the only glob and every tracked path named
   explicitly, there is no wildcard that could match a future secret or scratch file.
3. **Every committed file is deliberate.** The allowlist *is* the inventory of intentionally
   tracked content; "what does this repo track?" is a single file to read.
4. **Reviewable additions.** A new tracked file appears in review as an `.gitignore`
   allowlist edit, not as a silent inclusion.
5. **Catch the one failure mode.** The strategy's only friction — forgetting to allowlist a
   genuinely wanted file — must be caught mechanically, not left to notice-after-merge.
6. **Org consistency.** The repo should match the portfolio's baseline so contributors learn
   the pattern once.

## Considered Options

1. **Allow-all with explicit denies (community default).** Track everything; enumerate
   patterns to skip.
2. **Deny-all with explicit allowlist (chosen).** First non-comment rule is `**`; every
   tracked path is an explicit `!`-prefixed entry.
3. **`git add` discipline only.** No structural `.gitignore`; rely on contributors to add
   paths individually.

## Decision Outcome

Chosen option: **Option 2 — deny-all with an explicit allowlist**, adopting the org
baseline and adding a repo-local CI guard.

`.gitignore` is organized as follows:

- The first non-comment, non-blank line is `**` (ignore everything). It is the **only**
  glob in the file.
- Every tracked path is a subsequent `!`-prefixed allowlist entry, grouped by category with
  `#` comments (repository-root governance/tooling, `ansible/`, `terraform/` data-only,
  `docs/`, `.github/`).
- A directory requires **two** entries — one for the directory (`!/path/`) and one for its
  contents (`!/path/**`) — because a single entry does not suffice in all git versions.
- Adding a **new** committed file requires adding its allowlist line in the **same** pull
  request. A PR that adds a file without allowlisting it is a reviewer-detectable defect:
  the file will not appear in `git status` after `git add`.
- The allowlist MUST NOT re-admit broad trees. Generated content — `_dev-build/`, Terraform
  state, caches, `.env`, agent tooling — is never allowlisted and lives on disk only.

### The forgot-to-allowlist CI guard

The Makefile `allowlist-check` target (part of `make ci`) is the mechanical guard for the
strategy's single failure mode. It lists ignored-but-untracked files inside the deliverable
trees (`ansible terraform docs .github`), filters out the intentionally-ignored paths
(`.terraform/`, `*.tfstate`, `__pycache__`, `*.retry`, the framework-owned
`linux_disk_manager/` composed in at run time), and **fails** if anything remains:

```
git ls-files --others --ignored --exclude-standard -- ansible terraform docs .github
```

A non-empty result means someone added a deliverable-area file but forgot the matching
`!/<path>` line — the file would be silently dropped from the repo. The guard prints the
offending paths and exits non-zero, turning "silently not committed" into a loud CI
failure. The inverse case — a tracked file that should be ignored — is caught in review as
an allowlist edit that admits something it should not.

## Pros and Cons of the Options

### Option 1: Allow-all with explicit denies (community default)

- **Good, because** it is the dominant convention; contributors recognize it without
  explanation.
- **Good, because** ecosystem templates drop in with minimal edits.
- **Bad, because** anything not denied is tracked; a forgotten deny for `tfstate`, `.env`,
  or a cert key is an immediate compromise in this secret-dense repo.
- **Bad, because** there is no review-time signal distinguishing an intentional new tracked
  file from one swept in by `git add .`.

### Option 2: Deny-all with explicit allowlist (chosen)

- **Good, because** new files default to ignored; no glob can sweep in a secret or scratch
  file.
- **Good, because** each tracked file is an explicit, reviewable allowlist edit, and the
  allowlist is the tracked-content inventory.
- **Good, because** the strategy's one failure mode is caught by `make allowlist-check` in
  CI, and the diagnostic for a surprised contributor is `git check-ignore -v <path>`.
- **Neutral, because** initial allowlist setup is a one-time effort proportional to the
  tracked surface.
- **Bad, because** it is unusual; a contributor may be surprised when a new file does not
  show up in `git status` until allowlisted.
- **Bad, because** each new directory needs two allowlist entries.

### Option 3: `git add` discipline only

- **Good, because** it requires no rule maintenance.
- **Bad, because** human discipline is the weakest control; a single `git add .` undoes it.
- **Bad, because** it defends against nothing automatic (IDE writes, agent tooling, staged
  credentials) and gives no review-time signal.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms. The wording `MUST`,
`SHOULD`, and `MAY` follows [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

1. **Deny-all first line.** The first non-comment, non-blank line of `.gitignore` MUST be
   `**`, and it MUST be the only glob in the file. A reviewer SHOULD reject any additional
   wildcard.
2. **Allowlist after deny.** All `!`-prefixed entries MUST appear after `**`. A reversed
   order silently negates the strategy.
3. **New file ⇒ allowlist edit.** A PR that adds a committed file MUST add its `!/<path>`
   line in the same change. `make allowlist-check` MUST pass in CI.
4. **No broad re-admission.** The allowlist MUST NOT re-admit generated trees (`_dev-build/`,
   `.terraform/`, `*.tfstate`), caches, `.env`, or credential material.
5. **`.gitignore` not edited outside intent.** The `.gitignore` is orchestrated as an
   allowlist; edits MUST add specific paths, not weaken the deny-all rule.

## Consequences

### Positive

- Terraform state, `.tfvars`, `.env`, AWS credentials, minted cert keys, `_dev-build/`, and
  caches cannot enter the repo through `git add .` alone.
- Every tracked file is a deliberate, reviewable allowlist entry; `.gitignore` is the
  tracked-content inventory.
- The one ergonomic failure — forgetting to allowlist a wanted file — is caught by
  `make allowlist-check` in CI rather than noticed after merge.
- The repo matches the org baseline, so the pattern is learned once across the portfolio.

### Negative

- Contributors unfamiliar with the pattern may be surprised when a new file does not appear
  in `git status`; the fix is `git check-ignore -v <path>` plus an allowlist line.
- Each new directory costs two allowlist entries.
- The allowlist must be maintained; a new deliverable subtree is a small, deliberate edit.

### Neutral

- Per-directory `.gitignore` files are not used; the single top-level file carries the whole
  deny-all + allowlist.
- The `allowlist-check` exclusion list (`.terraform/`, `*.tfstate`, `__pycache__`, `*.retry`,
  `linux_disk_manager/`) is itself part of the intent and is reviewed when it changes.
- The strategy is cheap to reverse: migrating back to allow-all-with-denies is a single PR,
  though doing so would forfeit the default-safe property this repo depends on.

## Assumptions

This decision rests on the following assumptions. If any becomes false, this ADR should be
revisited:

1. Git's `**` and `!`-prefixed pattern semantics continue to behave as documented in
   `gitignore(5)`.
2. The repo continues to carry high-sensitivity, non-committable content (Terraform state,
   credentials, minted keys, generated composition), so the default-safe property stays
   worth its friction.
3. The `make allowlist-check` guard remains part of `make ci` and runs on every pull
   request.
4. The framework-owned `linux_disk_manager/` role continues to be composed in at run time
   rather than tracked, so its exclusion from the guard remains correct.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

Pending. The strategy predates this ADR — `.gitignore` already opens with `**` and an
explicit allowlist, and `make allowlist-check` already guards it — so no new implementing
PR is required; this ADR records the repo-specific rationale and the local guard.

## Related ADRs

- [ADR-0003 (org)](../org/0003-use-deny-all-gitignore-strategy.md) — the org baseline this
  repo adopts. This repo-local ADR does not opt out; it records the repo-specific stakes and
  the `allowlist-check` guard.
- [ADR-0001 (repo)](0001-secrets-and-tls.md) — the rotate-every-run secrets and on-target
  key minting whose material this `.gitignore` keeps out of version control.
- [ADR-0002 (repo)](0002-combined-terraform-ansible-delivery.md) — the delivery model that
  produces the untracked `_dev-build/` composition and the Terraform state this strategy
  excludes.

## Compliance Notes

This ADR establishes a source-control hygiene practice contributing to prevention of
accidental disclosure. The table is illustrative, not exhaustive, and is not a claim of
compliance by adoption alone.

| Framework              | Control / Practice ID                                     | Potential Evidence Contribution                                                                                                     |
| ---------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | SC-28 (Protection of Information at Rest)                  | Deny-all `.gitignore` blocks Terraform state, `.env`, and cert keys from entering version control by accidental `git add`.        |
| NIST SP 800-53 Rev. 5  | SI-12 (Information Management and Retention)               | The explicit allowlist is a source-of-truth inventory of what the repository intentionally retains.                                |
| NIST SP 800-53 Rev. 5  | IA-5 (Authenticator Management)                            | Default-blocking credential-bearing files (`.env`, `*.pem`, `*.key`, `.tfvars`) reduces accidental authenticator commit.           |
| NIST SP 800-218 (SSDF) | PS.1 (Protect Code from Unauthorized Access and Tampering) | The reviewable allowlist edit creates a trail of what content is deliberately added to the tracked set.                            |
| OWASP                  | A02:2021 — Cryptographic Failures                         | Default-blocking `*.key`, `*.pem`, and state files reduces the most common vector for cryptographic-material disclosure.           |
