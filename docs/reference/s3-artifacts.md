# S3 artifacts

**Type**: Reference (Diátaxis). To use these artifacts in a deploy, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md); for safe credential handling, see [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md).

S3 is the source of truth for package artifacts and the dashboard's browser-listener certificate
pair. The controller mints a fresh artifact-reader session and 900-second GetObject URL for each
package-fetch attempt. Linux and Windows targets perform plain HTTPS GETs with no deploy or
standalone artifact-reader credential and no AWS SDK. Their SSM-only instance profile still
provides SSM-scoped credentials through instance metadata. Each target does receive the bearer URL
as a module argument. It embeds the temporary access-key identifier and session token and can be
replayed for its one read-only object until expiry, but it is not a reusable AWS credential set.
The dashboard listener pair is not presigned because it contains private key material; the
controller retrieves and pushes those four small files under a separate fresh session. Fresh
internal CA, indexer-node, securityadmin, and manager-API identities are minted on the AIO target
every run. Internal PKI never transits S3.

## Bucket naming

The org convention is an account- or org-scoped `*-ansible` artifact bucket. The tracked
per-environment overlays retain an invalid tripwire at `s3.bucket`; deployments must replace it
through the role override. GitHub workflows derive and export `ANSIBLE_S3_BUCKET` from their
existing org-global account-id input, while a local operator exports the bucket name explicitly.

| Setting | `dev` source |
|---|---|
| `s3.bucket` | Required `ANSIBLE_S3_BUCKET` controller environment variable |

Both playbook role override sites consume that variable. Role validation rejects an empty value
and the committed `<account-id>` tripwire before any S3 download.

## Objects the AIO server role reads

The `wazuh_server` role downloads one offline bundle, the dashboard listener pair, and the pair's
digest sidecars:

| Object | Overlay key | Notes |
|---|---|---|
| Offline bundle | `s3.bundle_key` | `functions/wazuh/4.14.5/wazuh-offline.tar.gz` (dev). Contains the indexer, manager, dashboard RPMs plus Filebeat module and template. |
| `dashboard.pem`, `dashboard-key.pem` | under `s3.certs_prefix` | Certificate and private key used only by the dashboard's browser-facing 443 listener. |
| `dashboard.pem.sha256`, `dashboard-key.pem.sha256` | under `s3.certs_prefix` | Companion digests checked before either PEM is installed. |

Current `dev` cert prefix:

| Setting | `dev` value |
|---|---|
| `s3.certs_prefix` | `functions/wazuh/certs` |

The dev configuration permits a self-signed placeholder only when its exact configured SHA-256
fingerprint matches. That exception proves custody and transfer without claiming a
production-trusted chain. Replace any placeholder with a certificate issued by a CA the intended
browsers already trust before treating the listener as production-trusted.

The controller pushes all four files into root-only target staging. The role reads the first
whitespace-delimited token from each sidecar and compares it with an independently computed
SHA-256 of the matching PEM. This accepts both bare-digest and standard `sha256sum` output. The
sidecars detect transfer or object mismatch but are not an independent trust anchor because they
share the same S3 custody boundary.

## Certificate custody

The prior internal-PKI objects have been deleted. The live certificate prefix contains exactly
four objects:

- `dashboard.pem`
- `dashboard.pem.sha256`
- `dashboard-key.pem`
- `dashboard-key.pem.sha256`

The role mints the internal CA and all three internal identities on the target every run, and
destroys the CA private key after issuance. None of that material is downloaded from or uploaded
to S3. `dashboard-key.pem` is therefore the single private key in external custody.

## Objects the agent role reads

The `wazuh_agent` role does **not** unpack the central bundle. It downloads exactly one
standalone package per platform:

| Object | Overlay key | `dev` value |
|---|---|---|
| Standalone agent RPM (Linux) | `s3.agent_rpm_key` | `applications/wazuh-agent/wazuh-agent-4.14.5-1.x86_64.rpm` |
| Standalone agent MSI (Windows) | `s3.agent_msi_key` | `applications/wazuh-agent/wazuh-agent-4.14.5-1.msi` |

The controller signs each package key immediately before every attempt. Linux uses
`ansible.builtin.get_url`; Windows uses `ansible.windows.win_get_url`. Both modules normalize and
receive the trusted SHA-256 identically, so corrupt bytes fail during download rather than
reaching the package installer. Each failed attempt's bearer URL and temporary session are
scrubbed before the next attempt is minted.

## SHA-256 pins

Package artifacts are verified against a trusted hash during download. A mismatch aborts the
transfer before installation.

| Pin | Overlay key | Applies to |
|---|---|---|
| Bundle hash | `s3.bundle_sha256` | The `get_url` transfer of `wazuh-offline.tar.gz` (server role). Current `dev`: `1a60b8c407a56ed45a1e431256f6c49cba083a329874be7b532ec48a56069bea`. |
| Dashboard pair digests | `<PEM>.sha256` companion objects | The downloaded dashboard certificate and private key. These are verified before installation. |
| Agent RPM hash | `s3.agent_rpm_sha256` | The downloaded agent RPM (Linux agent role). The agent role additionally asserts this is a real 64-character hex value before downloading. |
| Agent MSI hash | `s3.agent_msi_sha256` | The downloaded agent MSI (Windows agent role). Same real-64-character-hex assertion, checked before the target HTTPS fetch. |

When you re-upload an artifact, recompute the hash with `sha256sum` and update the matching overlay key in the same PR.

## Object layout summary

```text
s3://<bucket>/<bundle_key>                          # wazuh-offline.tar.gz  (server role)
s3://<bucket>/<certs_prefix>/dashboard.pem           # dashboard 443 listener certificate
s3://<bucket>/<certs_prefix>/dashboard.pem.sha256    # certificate digest sidecar
s3://<bucket>/<certs_prefix>/dashboard-key.pem       # dashboard 443 listener private key
s3://<bucket>/<certs_prefix>/dashboard-key.pem.sha256 # private-key digest sidecar
s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.x86_64.rpm   # agent role (Linux)
s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.msi         # agent role (Windows)
```

## Role consumption and IAM scope

The roles consume these object subsets:

- **AIO server job**: mint and sign immediately before each
  `s3://<bucket>/<bundle_key>` fetch attempt, then retrieve exactly the four dashboard
  pair/sidecar objects under a separate controller session for push.
- **Agent job (Linux)**: sign
  `s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.x86_64.rpm` once per attempt.
- **Agent job (Windows)**: sign
  `s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.msi` once per attempt.

`secure-wazuh-artifact-read` is attached only to `secure-wazuh-artifact-reader`. It grants
object/version reads and listing under `functions/wazuh/*` and `applications/wazuh-agent/*`, plus
the bucket-location read. Those prefixes now contain only the offline bundle, the four dashboard
pair/sidecar objects, and the two agent packages listed above. The prefix grant is therefore
minimal in practice. The EC2 instance profile has no S3 policy; if the scoped session is missing or
expires, signing or controller retrieval fails. Step 0 binds the inspected profile to every
instance ID in the already validated run-scoped topology, rejects an instance with no profile or a
different profile, and rejects both role-attached artifact authority and a bucket-policy Allow for
the instance role. The same checks run again immediately before the first artifact fetch. A
presigned URL cannot expand the signer's permission: GetObject must be allowed to the signer or the
target HTTPS request is denied.
If a job also publishes artifacts, it additionally needs S3 write on the relevant object keys.

## Related

- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — the deploy that consumes these objects.
- [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md) — supplying the credentials that read them.
- [`reference/inventory-and-topology.md`](inventory-and-topology.md) — how the minted node name
  derives from the inventory hostname.
