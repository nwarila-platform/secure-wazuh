# Dependency declarations

This tree is this repository's declared dependency contract for the organization estates.
`dependencies/aws/` is desired state matching the proven fleet baseline and, as last exported on
2026-09-28, live AWS. That equality is a point-in-time claim re-established by a live round-trip,
not a guarantee that live state cannot later drift. The owner reviews this tree before any AWS
apply.

## Layout

`aws/policies/` contains one desired customer-managed IAM document per object.
Policy metadata lives in `aws/manifest.json`; per-policy sidecars were empty boilerplate, and
their `attached_to` lists duplicated the role-to-policy relationship the manifest already owns.
There is no `aws/proposed/` tree. Desired changes are made in the real policy files.

`aws/roles/` pairs each desired trust document with a role sidecar. Role sidecars remain because
they carry session duration, customer and AWS-managed attachments, trust filename, path, nullable
description, ownership, and the artifact-reader ratification.

`aws/manifest.json` keeps the exported date and authoritative role-to-policy attachments for the
closed export set: four roles, zero profiles, and sixteen customer-managed policies. Its `policies`
and `divergence` objects are declared local extensions to the golden manifest schema. `policies`
holds policy path, exact nullable description, tags, and ownership.
`divergence.not_yet_applied` remains present and empty: the tracked policy documents matched live
at the last export, and the mandatory live round-trip re-establishes that point-in-time claim.

`aws/artifacts.yml` declares exactly consumed S3 objects and their SHA-256 pins; IAM policy
documents separately declare authorization.
There is no `ad/` directory because this repository's verified AD footprint is empty.

## External dependencies

This repository's hosts launch with the shared instance profile `nwarila-ec2-profile` (registry-owned and declared by whichever repository owns the shared estate); `terraform/aws.tfvars` selects it for every system, and the runner holds `iam:PassRole` and `iam:GetInstanceProfile` on it.

## Future provider consumption

A future Terraform provider module can load documents without name-specific HCL.
The sketch below is intentionally future-facing; this piece performs no apply.

~~~hcl
locals {
  dependency_manifest = jsondecode(file("aws/manifest.json"))
  consumer_policies = {
    for name, metadata in local.dependency_manifest.policies : name => metadata
    if metadata.managed_by == "consumer"
  }
  policy_documents = {
    for name, metadata in local.consumer_policies : name =>
    replace(
      replace(
        replace(
          replace(
            replace(
              replace(
                replace(
                  replace(file(format("aws/policies/%s.json", name)), "<account-id>", var.account_id),
                  "<owner-id>", var.owner_id),
                "<repository-id>", var.repository_id),
              "<region>", var.region),
            "<vpc-id>", var.vpc_id),
          "<subnet-id>", var.subnet_id),
        "<ebs-kms-key-id>", var.ebs_kms_key_id),
      "<key-pair-name>", var.key_pair_name)
  }
}
~~~

Role sidecars use `yamldecode`, `fileset`, and `for_each` in the same way.
The eight replacement tokens are the closed token vocabulary for canonical AWS documents; a
document uses only the members its live content requires.

## Registry shim

`registry-values.yml` is the sacrificial local resolver.
Delete that one file when the organization registry exists; declarations retain their URIs.
It contains only values genuinely referenced by machine declarations, in both directions.
The resolver makes declaration files provider-portable.
Canonical AWS documents are already portable through the eight tokens.
They therefore keep native AWS ARNs and names and have no resolver entries.

## Integrity

Every file below `dependencies/`, except `MANIFEST.sha256`, is covered by the manifest.
The SHA-256 of `MANIFEST.sha256` is the bundle digest naming the entire declaration set.
Regenerate it from the repository root with exactly:

~~~bash
cd dependencies && LC_ALL=C find . -type f ! -name MANIFEST.sha256 -print0 | LC_ALL=C sort -z \
  | xargs -0 sha256sum > MANIFEST.sha256
~~~

Verify it with exactly:

~~~bash
(cd dependencies && sha256sum -c MANIFEST.sha256)
~~~

The credential-free validator also checks schemas, metadata, object closure, tokens, literals,
desired/live divergence references, forbidden legacy layout, and symlinks. Its bare 12-digit scan
uses alphanumeric boundaries because SHA-256 digests can contain 12-digit runs. The current live
baseline uses `<account-id>`, `<owner-id>`, `<repository-id>`, and `<region>`. It does not use
`<vpc-id>`, `<subnet-id>`, `<ebs-kms-key-id>`, or `<key-pair-name>` because those four appeared only
in the removed hardening and not in the retained live documents.

## Known gaps

- The artifact-reader is live but disconnected: its trust names dead principals, the runner has
  no `sts:AssumeRole`, and its last use was 2026-08-09. It is scheduled for M1 retirement.
- Live `admin_s3` allows object management under `applications/wazuh/*`, but that prefix is empty;
  the two consumed agent installers are under `applications/wazuh-agent/*`. This is a real defect
  in the fleet baseline and is preserved here because desired state now matches the proven live
  baseline.
- The five certificate objects are published but not consumed yet; each is
  `status: proposed-m1`.
- Live `runner_s3` grants `s3:GetObject` on the domain-join secret, the VPN profile, and
  `<account-id>-apprepo/*`; no code path in this repository consumes any of them. These grants are
  SAFE-TO-REMOVE based on repository and live-object evidence, but remain in the fleet baseline
  pending a separately reviewed fleet-wide hardening change.
- The apprepo role, profile, and `nwarila-apprepo-read` are excluded because reach is transitive
  through `PassRole`, not a configured dependency.
- `docs/reference/aws-iam/` remains the tooling source until piece 3b.
  The desired declaration tree and tooling tree coexist deliberately during this additive piece.
- Active Directory has a verified empty footprint, so absence of `ad/` is intentional.

## Copy this pattern

The next consumer should declare only the objects it owns, keep policy metadata and authoritative
attachments in one manifest, preserve role sidecars where they carry real data, record external
shared estate without redeclaring it, and close every URI, attachment, token, literal, checksum,
and divergence reference in its validator.
