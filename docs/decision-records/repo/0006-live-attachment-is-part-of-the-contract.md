# ADR-0006: Live Attachment Is Part of the IAM Contract

| Field          | Value                                                   |
| -------------- | ------------------------------------------------------- |
| Status         | Accepted                                                |
| Date           | 2026-08-03                                              |
| Authors        | Smarter > Harder (@NWarila)                             |
| Decision-maker | Smarter > Harder (@NWarila)                             |
| Consulted      | None.                                                   |
| Informed       | None.                                                   |
| Reversibility  | Medium                                                  |
| Review-by      | N/A (Accepted)                                          |

## Context

Two failures on 2026-08-03 shared one cause: every verification this repository performed compared
documents to documents, and none compared a document to the authority it was supposed to be
exercising.

**A policy nobody uses still verifies clean.** `secure-wazuh_deploy-ec2.json` was detached from
every role when the live policy was split into `-launch` and `-lifecycle` on 2026-07-29. It stayed a
tracked source for five days. Edits to it — including a key-pair pin written specifically to
constrain the unified-key cutover — were applied to the live policy of the same name, read back,
and confirmed byte-identical. The confirmation was true and worthless: `AttachmentCount` was 0, so
the statement governed nothing. The launch policy that *was* attached still pinned the retired key
pair.

**A placeholder survives a source-versus-live diff.** `deploy-discovery-iam` was applied with the
literal token `<region>` left in `aws:RequestedRegion`. No region matches the string `<region>`, so
the condition never satisfied and every `ec2:Describe*` fell to an implicit deny; `terraform apply`
died 47 seconds in, unable to read an AMI. The source-versus-live comparison passed, because the
tracked source contains `<region>` by design and live now contained it too. Comparing a template to
a target rendered from that template cannot detect an unrendered template.

`check-iam-literals.sh --materialized` would have caught the second failure. It was not run, because
nothing required it to be: the apply path was a hand-typed `aws iam create-policy-version` against
a file, not a gated procedure.

## Decision

**A tracked IAM source is in force only if live IAM both matches it and is attached to the principal
that needs it. Verification asserts both, and applies go through a gated script rather than a
hand-typed AWS call.**

Three things follow:

1. **Applies are scripted.** `scripts/bootstrap-iam.sh` materializes into an untracked tree,
   runs the substitution gate, validates every document through Access Analyzer, and only then
   writes. It plans by default; writing requires `--apply`. Hand-typed `aws iam` mutations of these
   policies are not an accepted path — a placeholder cannot reach live through the gated one.

2. **Drift detection compares source to live, and includes attachment.** `--check-drift` fails on a
   document difference *and* on a policy that is absent, unattached, or attached to a principal the
   role-to-policy map does not declare. Attachment is the half that was missing; it is what makes a
   detached policy an error rather than a clean pass.

3. **A retired policy is deleted from the repository, not left tracked.** A source with no live
   attachment is indistinguishable from a live one by reading the repository, which is precisely how
   five days of edits went nowhere.

## Consequences

Verification now costs a live AWS read; the source tree alone is no longer sufficient evidence, and
`--check-drift` needs credentials. That is the point — the previous cheap check is what passed while
the boundary was unenforced.

The 6,144-character managed-policy limit makes future splits likely, and every split creates this
exact hazard: a new live object plus a stale tracked source that still verifies. The attachment
assertion is what makes the next split fail loudly instead of silently.

This ADR does not change any boundary's *content*. `RunInstancesImagesFromTrustedOwners` keeps the
owner list [[ADR-0005]] settled empirically; `RunInstancesWithPinnedKeyPair` keeps its pin. It
changes only what the repository is willing to call proven.

## Alternatives considered

**Read live back after each apply and diff it.** Already done, and it is what produced two false
confirmations. It answers "did my write land" — never "is this policy attached" or "was the source
rendered."

**Have Terraform manage IAM.** Attachment and drift both become state, which is a genuine fix. It is
rejected here for the same reason recorded in this directory's README: an operator provisions IAM
and Terraform consumes it, so the deploy role would need authority to rewrite its own boundary.

**Rely on the deploy failing.** It does fail, but only for the permissions a run happens to
exercise, and only after standing up infrastructure. The detached launch policy would have surfaced
as a `RunInstances` denial minutes into a paid run; the unattached statement it should have been
enforcing would not have surfaced at all.
