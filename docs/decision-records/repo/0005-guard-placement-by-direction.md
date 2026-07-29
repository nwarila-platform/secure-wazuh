# ADR-0005: Guard Placement by Direction

| Field          | Value                           |
| -------------- | ------------------------------- |
| Status         | Accepted                        |
| Date           | 2026-07-29                      |
| Authors        | Smarter > Harder (@NWarila)     |
| Decision-maker | Smarter > Harder (@NWarila)     |
| Consulted      | None.                           |
| Informed       | None.                           |
| Reversibility  | Medium                          |
| Review-by      | N/A (Accepted)                  |

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

The policy does not require `ec2:AssociatePublicIpAddress = false`. This deployment reaches SSM
through an internet gateway from a public subnet, so such a condition would stop every run. Public
addressing is an accepted residual, compensated by administrative access through SSM rather than
inbound SSH, per-ENI security groups, and IMDSv2 required at launch.

## Consequences

**Positive.** The normal path remains pinned to the exact tested image while IAM blocks launches
from untrusted publishers when that path is bypassed. Routine image refreshes remain deployment
data changes rather than live IAM operations, and the IAM statement stays smaller than an
ever-growing image-ID list.

**Negative.** The IAM boundary permits another image owned by an approved publisher or by the
deploy account. A compromised session can choose such an image directly. That is the intended
blast radius: exact selection belongs to the framework path, while IAM excludes the higher-risk
untrusted-publisher set.

**Accepted residual.** Instances may need public addresses to reach SSM on the current public-subnet
topology. SSM-only administration, interface-specific security groups, and required IMDSv2 reduce
the exposure but do not remove public addressing.

**Implied follow-on.** `terraform/aws.tfvars` still carries a bare `ami = "ami-..."` per system, so
the consumer hand-picks an image ID and the framework offers no baseline to select from. Under this
principle that is backwards. The framework carrying a blessed set, so a consumer names a platform
and receives the STIG-hardened image, is the implied direction.
