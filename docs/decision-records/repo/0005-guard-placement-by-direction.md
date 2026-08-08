# ADR-0005: Guard Placement by Direction

| Field          | Value                                                   |
| -------------- | ------------------------------------------------------- |
| Status         | Accepted (amended 2026-07-29)                           |
| Date           | 2026-07-29                                              |
| Authors        | Smarter > Harder (@NWarila)                             |
| Decision-maker | Smarter > Harder (@NWarila)                             |
| Consulted      | None.                                                   |
| Informed       | None.                                                   |
| Reversibility  | Medium                                                  |
| Review-by      | N/A (Accepted)                                          |

> **Status note.** Accepted 2026-07-29. The 2026-07-29 amendment below replaces the worked
> image-owner outcome with the empirically enforceable boundary. The guard-placement principle is
> unchanged. Where the historical body pins the CIS publisher account or excludes
> `aws-marketplace`, this amendment governs.

## Amendment — 2026-07-29: use the owner alias IAM evaluates

The placement decision is unchanged: Terraform selects the exact tested AMI, while IAM constrains
the image-authorization leg that remains reachable when Terraform is bypassed. Empirical
authorization and copy tests established the boundary this account can enforce:

- `ec2:Owner` evaluates an image's owner alias when the image has one. With a throwaway role whose
  owner list pinned the CIS publisher account, a dry-run launch allowed the Windows image
  (`amazon`) but refused the CIS RHEL image (`aws-marketplace`, backed by that publisher account).
  Pinning the publisher account therefore denies the CIS image the example intends to admit.
- The CIS image cannot instead be copied into this account. `CopyImage` failed because the caller
  had no permission to access the marketplace image's backing storage. Its dry run reported
  success because dry-run checks IAM authorization, not that storage restriction.

The achievable IAM owner boundary is therefore:

```json
"ec2:Owner": ["amazon", "aws-marketplace", "<account-id>"]
```

`amazon` admits the Amazon-published Windows image, `aws-marketplace` admits the CIS RHEL image by
the alias IAM actually evaluates, and `<account-id>` is forward-looking for images built in this
account. The Marketplace alias is broader than a publisher-specific trust anchor. That is the
accepted limitation of this worked example; it does not move exact image selection out of the
framework or change the directional guard-placement decision.

## TL;DR

The framework helps consumers baseline to the preferred EC2 templates; IAM blocks the high-risk
public templates. These controls divide by **direction**:

- A **framework guard** is a positive affordance. It makes the tested, hardened choice the easy
  one, so a consumer selects a platform rather than an image ID. It is unlimited by IAM policy
  size, readable, testable, and versioned with the templates it describes. It binds only when the
  framework code path runs, so it does not defend against a compromised session calling the API
  directly.
- An **IAM guard** is a negative boundary. It still holds when the deploy code is bypassed and
  defines the resulting blast radius. It consumes characters from the hard 6,144-character
  managed-policy budget, and changing it is a live production operation.

Because the controls point in opposite directions, they should not duplicate one another. Where
they do, the expensive control is usually doing the cheap control's job.

## Context and Problem Statement

`terraform/aws.tfvars` currently carries an exact `ami = "ami-..."` value for each system. That is
already a framework guard: the ordinary Terraform path launches the declared image and fails on
drift from that value. It gives the repository a precise, readable image selection that changes
with the deployment data.

IAM must address a different path. A compromised deploy session can bypass Terraform and call
`RunInstances` directly. The IAM policy therefore needs to prevent launches from untrusted
publishers without repeating each exact AMI selection. Repeating the image IDs in IAM would spend
limited policy space on values already enforced by the framework path, make every routine image
refresh a live IAM change, and turn a stale IAM pin into an undiagnosable launch denial.

The distinction matters beyond this example. Framework checks can be expressive and evolve with
the code they describe, but disappear when that code is bypassed. IAM is always present for the
credential, but its constrained document should be reserved for the blast radius that must remain
when the preferred path is absent.

## Decision Drivers

- Make the tested, hardened platform the easy choice in the normal deploy path.
- Preserve a meaningful boundary when deploy code is bypassed.
- Keep routine image refreshes out of live IAM changes.
- Reserve the 6,144-character IAM budget for controls that only IAM can enforce.
- Keep each rule readable and versioned with the thing it describes.
- Avoid duplicate controls whose failure produces opaque authorization denials.

## Considered Options

1. **Pin exact AMI IDs in both Terraform data and IAM.** The normal path and direct API path both
   accept only the current IDs.
2. **Keep exact image selection in the framework path and restrict publishers in IAM (chosen).**
   Terraform selects the precise image; IAM excludes untrusted publishers even when Terraform is
   bypassed.
3. **Keep exact image selection only in the framework path.** Terraform remains precise, but a
   bypassed path can launch any public image.

## Decision Outcome

Chosen option: **Option 2 — positive framework selection with a negative IAM publisher boundary.**

R4-2 proposed pinning `ec2:ImageId`. That is rejected because the exact AMI is already a framework
guard in `terraform/aws.tfvars`, where Terraform fails on drift. Duplicating it in IAM would make
every routine image refresh a live IAM change, and a stale pin would surface only as a launch
denial. IAM instead constrains the image authorization leg with:

```json
"ec2:Owner": ["amazon", "679593333241", "<account-id>"]
```

`amazon` covers the Amazon-published Windows Server 2025 STIG Core image. `679593333241` is the
public CIS marketplace publisher account for the CIS RHEL 8 Benchmark STIG image. `<account-id>`
retains images built by this account without committing its real ID; the standard materialization
step replaces the placeholder before application. The broad `aws-marketplace` namespace is not a
trust anchor and is excluded.

The policy does not require `ec2:AssociatePublicIpAddress = false`. This deployment reaches the
internet through a gateway from a public subnet, so such a condition would stop every run.

**Amended 2026-08-07.** This paragraph previously read that public addressing was "compensated by
administrative access through SSM rather than inbound SSH". That is no longer true and should not
be relied on. The PoC now proves five connection transports against one topology, and three of the
five agent legs are reached WITHOUT SSM — two over SSH direct to tcp/22 and one over WinRM/HTTPS on
tcp/5986. Inbound administrative access is deliberate and load-bearing, not an oversight: the
permanent target does not permit SSM at all, so a proof carried entirely over SSM would demonstrate
nothing transferable to it.

What actually bounds the exposure now:

- **One address, for one run.** Inbound comes from a single security group the framework creates
  only when `runner_ip` is passed at apply, carrying tcp/22, tcp/5986 and ICMP from exactly
  `<runner_ip>/32`. The variable takes a bare IPv4 address and never a CIDR, so a range is not
  merely rejected by validation — it is unrepresentable in the input type.
- **Destroyed with the stack.** The group is a Terraform resource, so teardown removes it. There is
  no revoke step that can be skipped by a cancelled job and no stale rule for a reaper to find.
- **Nothing standing.** Every declared `ingress` in `terraform/aws.tfvars` is empty apart from the
  AIO's agent-facing 1514/1515 and dashboard 443, both scoped to the deploy subnet CIDR. Absent
  `runner_ip`, the topology has no inbound administrative path at all.
- **Unchanged from before.** Per-ENI security groups and IMDSv2 required at launch still apply.

The residual is therefore narrower than the original wording implied in one respect — a single /32
for the life of one run, rather than an open administrative surface — and wider in another: it is
real inbound access, where the ADR previously claimed there was none.

## Consequences

**Positive.** The normal path remains pinned to the exact tested image while IAM blocks launches
from untrusted publishers when that path is bypassed. Routine image refreshes remain deployment
data changes rather than live IAM operations, and the IAM statement stays smaller than an
ever-growing image-ID list.

**Negative.** The IAM boundary permits another image owned by an approved publisher or by the
deploy account. A compromised session can choose such an image directly. That is the intended
blast radius: exact selection belongs to the framework path, while IAM excludes the higher-risk
untrusted-publisher set.

**Accepted residual.** Instances hold public addresses on the current public-subnet topology, and
three of the five agent legs accept inbound administrative connections from the runner's `/32` for
the life of a run. Run-scoped ingress, per-ENI security groups, and required IMDSv2 bound the
exposure; they do not remove it. The SSM-only claim that previously stood here was retired on
2026-08-07 — see the amendment above.

**Implied follow-on.** `terraform/aws.tfvars` still carries a bare `ami = "ami-..."` per system, so
the consumer hand-picks an image ID and the framework offers no baseline to select from. Under this
principle that is backwards. The framework carrying a blessed set, so a consumer names a platform
and receives the STIG-hardened image, is the implied direction.
