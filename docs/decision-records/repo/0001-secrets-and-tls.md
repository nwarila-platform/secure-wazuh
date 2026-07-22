# ADR-0001: Two-Tier PKI and a Rotate-Every-Run Secrets Model

| Field          | Value                                       |
| -------------- | ------------------------------------------- |
| Status         | Accepted (partially implemented — see banner) |
| Date           | 2026-07-21                                  |
| Authors        | Smarter > Harder (@NWarila)                 |
| Decision-maker | Smarter > Harder (sole portfolio maintainer) |
| Consulted      | None.                                       |
| Informed       | None.                                       |
| Reversibility  | Medium                                      |
| Review-by      | N/A (Accepted)                              |

> **⚠️ Implementation status.** The **secrets model** (decisions 2 & 3 below — one operator
> password, rotate-every-run internal service users as bcrypt-only, manager-API users derived
> from the admin password, plaintext-off-disk mitigations) **is implemented** in the
> `wazuh_server` role today. The **two-tier PKI** (decision 1 — internal CA/node/admin certs
> minted *on the target*, client certs dropped, only a distinct dashboard cert from S3) is the
> **target design and is NOT yet implemented**: the role currently downloads `root-ca.pem` /
> `admin.pem` / node PEMs from S3 and reuses the node cert for the indexer, Filebeat, and
> dashboard (the pre-decision flow documented in [`reference/s3-artifacts.md`](../../reference/s3-artifacts.md)).
> The PKI rework is tracked, not shipped — read decision 1 below as the intended end state.

## TL;DR

`secure-wazuh` deploys a STIG- and FIPS-hardened Wazuh 4.14.5 all-in-one SIEM
(indexer/OpenSearch + manager + Filebeat + dashboard, plus endpoint agents). This
ADR records three linked decisions about how that stack gets its TLS material and
its secrets:

1. **Two-tier certificates.** A self-signed **internal PKI** (CA + node + admin
   certificate) is minted **on the target at deploy time** and used only for the
   OpenSearch transport, HTTP/REST, and `securityadmin` layers. Those layers are
   loopback / backend-only on an all-in-one and are never browser-facing. A single
   **dashboard public certificate/key** is **pulled from S3** so that browser
   consumers of the dashboard reach a service whose certificate chains to a CA they
   already trust. The old per-component Filebeat and dashboard **client**
   certificates are dropped; those hops now authenticate with a **password plus
   CA-verification** of the server certificate.
2. **Plaintext off disk, best-effort for STIG.** bcrypt hashes (`internal_users.yml`)
   and component keystores (OpenSearch, manager, Filebeat, dashboard) carry the
   overwhelming majority of secrets. The one irreducible plaintext credential is the
   dashboard-to-manager API password in the Wazuh app's `wazuh.yml`. Documented
   mitigations apply.
3. **Rotate-every-run, nothing-persisted.** Because delivery is a commit-to-main
   GitOps loop (see [ADR-0002](0002-combined-terraform-ansible-delivery.md)),
   internal PKI and indexer internal-user passwords are minted fresh on every run and
   nothing is persisted between runs. The sole exception is the two **manager-API
   users** (`wazuh`, `wazuh-wui`): they are derived **deterministically** from
   `admin_password` so they remain stable across reruns and can still authenticate
   against a persisted RBAC database.

## Context and Problem Statement

Wazuh's all-in-one topology co-locates four TLS-bearing surfaces on one host:

- The **OpenSearch transport** layer (node-to-node, tcp/9300).
- The **OpenSearch HTTP/REST** layer (tcp/9200), which on an all-in-one is reached
  only over the loopback interface by two local clients: Filebeat and the dashboard
  backend.
- **`securityadmin`**, the tool that initializes the OpenSearch security index from
  `internal_users.yml`, `roles.yml`, and `roles_mapping.yml`. It authenticates with
  an admin certificate against the PKI.
- The **dashboard's browser listener** (tcp/443), the only surface a human ever
  points a web browser at.

The prior model pulled *every* certificate PEM — CA, node, admin, a Filebeat client
cert, and a dashboard client cert — from S3, and used per-object IAM scoping to keep,
for example, the dashboard host from reading `admin-key.pem`. That model has two
problems for a STIG/FIPS posture:

- **It treats internal, loopback-only PKI as if it were externally managed.** The
  transport/HTTP/`securityadmin` certificates never leave the host and are only ever
  presented to co-located clients that pin the internal CA. Distributing their keys
  through S3 (and then scoping them per host in IAM) adds an external key-custody
  surface and a rotation dependency for material that has no business leaving the
  machine that minted it.
- **It scatters private keys and it under-uses hashing and keystores.** STIG wants
  plaintext authenticators off disk wherever a mechanism exists to hash or vault them.
  Shipping standalone client keys (`filebeat-key.pem`, a dashboard client key) works
  *against* that goal when the same authentication can be done with a keystore-held
  password plus server-certificate verification.

Separately, a genuine tension exists: some daemons must authenticate over the wire and
therefore need a recoverable secret at runtime. The question is not "can we eliminate
all plaintext" (we cannot) but "how small can we make the irreducible plaintext, and
how well can we contain what remains."

Finally, the delivery model (ADR-0002) redeploys the stack on **every commit to main**
— in place on the permanent Proxmox instance and from zero on the ephemeral AWS
proof-of-concept. That makes "rotate on every run" cheap and desirable, but it collides
with one piece of durable state: the Wazuh **manager RBAC database** on the persistent
data volume, which is not wiped between runs. Any credential the manager persists must
survive a rerun.

## Decision Drivers

1. **Smallest possible externally-custodied key surface.** The only private key that a
   system outside the target should hold is the one that fronts real browser users.
2. **STIG "authenticators at rest" posture.** Prefer bcrypt hashes and keystores over
   plaintext; where plaintext is irreducible, contain it with ownership, mode, SELinux,
   fapolicyd, `no_log`, and a short lifetime.
3. **No browser trust warnings.** Training operators to click through certificate
   errors is itself a finding. The one browser-facing surface must present a
   trusted chain.
4. **FIPS-approved cryptography.** On-target minting must use FIPS-validated
   primitives (approved key types and SHA-2 digests) so the self-signed PKI is
   admissible under the hardened baseline.
5. **Idempotent redeploys.** The rotate-every-run loop must not require a manual
   credential-reset dance against durable manager state on each commit.
6. **Least privilege between co-located components.** Dropping client certs must not
   weaken authentication; password + CA-verify must be a real authentication, not an
   anonymous bind.

## Considered Options

1. **All certificates from S3 (prior model).** CA, node, admin, Filebeat client, and
   dashboard client PEMs distributed from S3 with per-object IAM scoping.
2. **All certificates self-signed on-target, including the dashboard.** Mint everything
   locally, including the 443 listener certificate.
3. **Two-tier: internal PKI minted on-target + dashboard public certificate from S3
   (chosen).** Self-signed internal CA/node/admin on the host; a single trusted
   dashboard cert/key pulled from S3; Filebeat and dashboard backend hops move to
   password + CA-verify.
4. **Public CA / ACME for every surface.** Obtain trusted certificates (e.g. via ACME)
   for transport, HTTP, and the dashboard alike.

## Decision Outcome

Chosen option: **Option 3 — two-tier certificates, plaintext-off-disk best-effort, and
a rotate-every-run model with two deterministic exceptions.**

### Part A — Two-tier certificates

**Internal PKI (self-signed, minted on the target at deploy time).** The deploy mints,
on the host, a self-signed root CA and, from it, a node certificate and an admin
certificate, using FIPS-approved key types and SHA-2 digests. The node certificate's
SANs cover `localhost`, `127.0.0.1`, and the node's own name. These certificates serve:

- OpenSearch **transport** (tcp/9300) node identity and node-to-node mutual TLS;
- OpenSearch **HTTP/REST** (tcp/9200) server identity, reached only over loopback by
  co-located clients;
- **`securityadmin`**, which uses the admin certificate to initialize and re-apply the
  security index.

Private keys never leave the host. The CA key is either discarded after the node and
admin certificates are issued or retained `0600` root-owned solely to re-mint on the
next run; because the model rotates every run (Part C), retention is optional.

**Dashboard public certificate/key (pulled from S3).** The dashboard's 443 listener
(`opensearch_dashboards.yml` `server.ssl.certificate` / `server.ssl.key`) uses a
certificate issued by a CA that browser consumers already trust — the organization's
internal issuing CA or a public CA. It is pulled from S3 at deploy time. This is the
**only** surface a human browser reaches and therefore the only one that must present a
trusted chain. It is also the **only** private key any external system (S3 + IAM) needs
to custody.

**Drop per-component client certs → password + CA-verify.** The two remaining internal
hops stop presenting client certificates:

- **Filebeat → indexer.** Filebeat authenticates as the internal writer user
  (bcrypt-hashed in `internal_users.yml` on the indexer; the plaintext lives only in
  the Filebeat keystore) and sets `output.elasticsearch.ssl.certificate_authorities` to
  the internal CA to verify the server. No client certificate.
- **Dashboard backend → indexer.** The dashboard authenticates as the `kibanaserver`
  internal user, with the password held in the dashboard keystore (not plaintext YAML)
  and `opensearch.ssl.certificateAuthorities` set to the internal CA. No client
  certificate.

Net effect: `admin-key.pem`, the node key, and the former `filebeat-key.pem` and
dashboard client key are all either minted-and-kept-on-target or eliminated. The
per-object IAM gymnastics the prior model needed (deny the dashboard host read on
`admin-key.pem`, etc.) disappear, because the only object under IAM scope is the
dashboard public key.

### Part B — Plaintext off disk, best-effort

- **bcrypt hashes.** OpenSearch internal-user passwords are stored as bcrypt hashes in
  `internal_users.yml`; the indexer hashes them at template-render time. They are never
  plaintext at rest.
- **Keystores.** Runtime plaintext that a daemon must present over the wire lives in
  that daemon's keystore, not its config file: the OpenSearch keystore on the indexer,
  the Filebeat keystore on the manager host (the writer password), and the
  OpenSearch-Dashboards keystore (`kibanaserver` password). Manager API users live in
  the manager's RBAC database, hashed, not in a plaintext config file.
- **The irreducible plaintext.** The Wazuh dashboard app plugin configuration
  (`wazuh.yml`, under the dashboard's `data/wazuh/config/` tree) records the manager
  API host entry with the API password **in plaintext**, because the Wazuh app reads it
  directly. This is the one credential that cannot currently be hashed or moved into a
  keystore by the plugin itself.

**Mitigations for the irreducible plaintext (in priority order):**

1. **Verify a keystore path first.** Confirm whether Wazuh **4.14.5** supports storing
   the dashboard-to-manager API password in the OpenSearch-Dashboards keystore (or any
   encrypted form the Wazuh app reads). If it does, use it and the irreducible plaintext
   disappears. This verification is a required step, not an assumption.
2. **If no keystore path exists, contain the file with defense in depth:**
   - mode `0600`;
   - ownership by the dashboard **service account**, or — the documented operator
     technique — **relocate the credentials file into the service account's HOME
     directory** (owner `root:<svc>`, `0600`, *outside* the world- or group-readable
     `/etc` and `/usr/share` config tree) so the secret does not sit in a broadly
     readable config path;
   - SELinux confinement (a targeted context on the file and the dashboard domain);
   - fapolicyd trust boundaries;
   - Ansible `no_log: true` on every task that renders or reads the password, so it
     never lands in logs or CI transcripts;
   - the rotate-every-run model (Part C), which bounds the lifetime of any captured
     value to a single deploy cycle.

### Part C — Rotate-every-run, nothing-persisted

The pipeline receives one stable root secret, `admin_password`, from its secret store;
it is never committed to the repository (see
[ADR-0003](0003-deny-all-explicit-gitignore.md)). From it, **every run** mints fresh
internal-PKI key material and fresh indexer internal-user passwords. `securityadmin`
re-initializes the OpenSearch security index wholesale on each run, and the matching
keystore values (dashboard `kibanaserver`, Filebeat writer) are rewritten in the same
run, so rotating those is free and self-consistent. Nothing is persisted between runs on
the controller or CI runner.

The deliberate exception is the two **manager-API users**, `wazuh` and `wazuh-wui`. The
Wazuh manager persists API users in its **RBAC database** (`rbac.db`) on the persistent
data volume of the permanent Proxmox instance. That database is treated as durable state
and is **not** wiped between runs. If the two API passwords were random per run, a rerun
against the persisted `rbac.db` would either fail to authenticate — the dashboard's
`wazuh.yml` would hold a value the manager no longer knows — or force a reset every
commit. Instead, the two passwords are **derived deterministically** from
`admin_password` (a keyed derivation with a distinct per-user label, e.g.
`HMAC-SHA256(admin_password, "wazuh-api:wazuh")` and `…:"wazuh-wui"`). Given a stable
`admin_password`, the derivation reproduces the same two passwords on every run, so a
rerun writes them idempotently to both `rbac.db` and the dashboard `wazuh.yml`, and
authentication holds with no reset step.

## Pros and Cons of the Options

### Option 1: All certificates from S3 (prior model)

- **Good, because** all certificate material is generated once, centrally, and audited
  in one place.
- **Good, because** a single generation tool produces a consistent set of PEMs.
- **Bad, because** it distributes internal, loopback-only private keys through an
  external object store and then needs per-object IAM scoping to re-contain them.
- **Bad, because** it ships standalone client keys that a keystore-held password plus
  CA-verify would obviate, working against the STIG "authenticators at rest" goal.
- **Bad, because** rotation of internal PKI now depends on an external upload step
  rather than a local mint.

### Option 2: All certificates self-signed on-target, including the dashboard

- **Good, because** no private key ever leaves the host and there is zero external key
  custody.
- **Good, because** it is the simplest possible generation story.
- **Bad, because** the browser-facing 443 listener would present a self-signed chain,
  training operators to click through certificate warnings — itself a finding.
- **Bad, because** it provides no path to a genuinely trusted service identity for
  human consumers.

### Option 3: Two-tier — internal PKI on-target + dashboard public cert from S3 (chosen)

- **Good, because** the only externally-custodied key is the one that fronts real users;
  everything internal is minted and kept on the host.
- **Good, because** browser consumers get a trusted chain with no warning-click
  training.
- **Good, because** dropping client certs in favor of keystore password + CA-verify
  advances the plaintext-off-disk posture and deletes the per-object IAM scoping the
  prior model required.
- **Good, because** on-target minting rotates for free under the commit-to-main loop.
- **Neutral, because** it splits certificate provenance into two mechanisms (mint vs.
  pull), which must both be documented.
- **Bad, because** the dashboard public certificate still requires an external issuance
  and renewal process outside this repo's control.

### Option 4: Public CA / ACME for every surface

- **Good, because** every surface would present a trusted chain.
- **Bad, because** the transport and loopback HTTP layers have no publicly resolvable
  identity to validate against; ACME does not fit an internal, loopback-only PKI.
- **Bad, because** it introduces an outbound issuance dependency into the deploy path of
  layers that never face the outside world.
- **Bad, because** it is disproportionate machinery for certificates that only
  co-located, CA-pinning clients ever see.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms. The wording `MUST`,
`SHOULD`, and `MAY` follows [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

1. **Internal-PKI provenance.** The transport, HTTP, and `securityadmin` certificates
   MUST be minted on the target at deploy time and MUST NOT be sourced from S3. A
   reviewer SHOULD reject any task that downloads `admin-key.pem`, a node key, or a CA
   key from object storage.
2. **Single external key.** The dashboard 443 certificate/key MUST be the only PKI
   object pulled from S3, and the S3/IAM policy SHOULD grant read on no other private
   key.
3. **No client certs on internal hops.** Filebeat's indexer output and the dashboard's
   `opensearch.*` backend config MUST authenticate with a keystore-held password and MUST
   set `ssl.certificate_authorities` / `ssl.certificateAuthorities` to the internal CA.
   Neither MAY present a client certificate.
4. **FIPS primitives.** On-target minting MUST use FIPS-approved key types and SHA-2
   digests. A reviewer SHOULD reject MD5/SHA-1 or non-approved key parameters.
5. **Hashes and keystores.** Indexer internal-user passwords MUST be bcrypt-hashed in
   `internal_users.yml`; the `kibanaserver` and Filebeat writer passwords MUST live in
   their component keystores, not plaintext config.
6. **Irreducible-plaintext containment.** The keystore-support verification for the
   dashboard-to-manager API password MUST be performed for 4.14.5. Absent a keystore
   path, `wazuh.yml` MUST be `0600`, owned by the service account (or relocated into the
   service account HOME per the documented technique), SELinux-confined, fapolicyd-covered,
   and every task touching it MUST set `no_log: true`.
7. **Deterministic API users.** The `wazuh` and `wazuh-wui` passwords MUST be derived
   deterministically from `admin_password` and MUST reproduce identically across reruns;
   a rerun against a persisted `rbac.db` MUST authenticate without a reset step.
8. **Nothing persisted.** No generated secret MUST be written into the repository or
   left on the CI runner between runs; `admin_password` MUST arrive from the secret store,
   not from tracked files.

## Consequences

### Positive

- The externally-custodied key surface shrinks to exactly one object: the dashboard
  public key. Per-object IAM scoping for internal keys is eliminated.
- Browser consumers reach a trusted dashboard; operators are never trained to accept
  certificate warnings.
- More secrets sit at rest as bcrypt hashes or in keystores; the irreducible plaintext
  is reduced to a single, contained file.
- Internal PKI rotates for free on every commit-to-main deploy, bounding the lifetime of
  any compromised internal key to one cycle.
- Idempotent redeploys hold against durable manager RBAC state without a reset dance.

### Negative

- Certificate provenance is now two mechanisms (on-target mint + S3 pull), which must be
  documented and understood together.
- The dashboard public certificate still depends on an external issuance/renewal process
  this repo does not own; an expired dashboard cert is an outage this repo cannot
  self-heal.
- One irreducible plaintext credential remains until (and unless) a 4.14.5 keystore path
  is confirmed; its containment depends on correct ownership, mode, SELinux, fapolicyd,
  and `no_log` all being right.
- Deterministic derivation of the two API users means a compromise of `admin_password`
  compromises those two users deterministically; the root secret must be guarded
  accordingly.

### Neutral

- The internal CA key may be discarded or retained `0600` root-owned depending on
  whether the operator wants local re-mint versus strict minimization; both are
  compatible with the model.
- Endpoint agents are outside this ADR's TLS scope; they enroll via `client.keys`
  (optionally gated by an enrollment password) rather than through the indexer PKI.

## Assumptions

This decision rests on the following assumptions. If any becomes false, this ADR should
be revisited:

1. The all-in-one topology keeps the OpenSearch HTTP/REST and transport layers
   loopback / backend-only, so their certificates never face a browser. A split-host
   topology that exposes 9200 to remote clients would change the trust analysis.
2. The FIPS-validated crypto module on the target provides the approved primitives the
   on-target mint requires.
3. `admin_password` is delivered as a stable secret from the pipeline's secret store and
   is guarded as the root of the two derived API credentials.
4. The manager RBAC database on the persistent volume is the only durable credential
   store that a rerun must not disturb; the indexer security index is safe to
   re-initialize wholesale each run.

## Supersedes

None. This ADR changes the certificate-distribution approach previously described in the
repository's operational notes (all PEMs from S3 with per-object IAM scoping); those
notes predate the ADR convention in this repository and are not themselves ADRs.

## Superseded by

None (current).

## Implementing PRs

**Landed**: the secrets/rotation model (decisions 2 & 3 — bcrypt/keystore-first plaintext
containment and the rotate-every-run model, including the deterministic manager-API user
derivation), implemented in the `wazuh_server` role.

**Pending**: the two-tier on-target PKI (decision 1) — the on-target internal-PKI mint, the
removal of the Filebeat and dashboard client-cert paths in favor of keystore password +
CA-verify, the dashboard public-cert S3 pull, and the 4.14.5 dashboard-keystore verification
for the API password.

## Related ADRs

- [ADR-0002 (repo)](0002-combined-terraform-ansible-delivery.md) — the commit-to-main
  delivery loop that makes rotate-every-run cheap and that stands up the two targets this
  secrets model runs on.
- [ADR-0003 (repo)](0003-deny-all-explicit-gitignore.md) — the deny-all `.gitignore` that
  keeps `admin_password`, minted keys, keystores, and Terraform state out of version
  control.
- [ADR-0003 (org)](../org/0003-use-deny-all-gitignore-strategy.md) — the org baseline the
  repo-local `.gitignore` ADR adopts.

## Compliance Notes

This ADR describes cryptographic-key management and authenticator-at-rest handling for a
hardened SIEM deployment. The table indicates where evidence produced under this decision
may help during reviews; it is illustrative, not exhaustive, and is not a claim of
compliance by adoption alone.

| Framework              | Control / Practice ID                                   | Potential Evidence Contribution                                                                                             |
| ---------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | SC-8 (Transmission Confidentiality and Integrity)       | Two-tier TLS protects transport, HTTP, and browser hops; CA-verify on internal hops confirms server identity.             |
| NIST SP 800-53 Rev. 5  | SC-12 / SC-13 (Cryptographic Key Establishment; Crypto Protection) | On-target FIPS-primitive minting and a single externally-custodied key document key establishment and use.       |
| NIST SP 800-53 Rev. 5  | SC-17 (Public Key Infrastructure Certificates)          | Internal self-signed PKI plus a trusted dashboard certificate document the certificate model per surface.                 |
| NIST SP 800-53 Rev. 5  | SC-28 (Protection of Information at Rest)                | bcrypt hashes and keystores keep most authenticators off disk in plaintext; the residual plaintext is contained.          |
| NIST SP 800-53 Rev. 5  | IA-5 (Authenticator Management)                          | Rotate-every-run bounds authenticator lifetime; deterministic API users document reproducible credential management.      |
| NIST SP 800-53 Rev. 5  | AC-6 (Least Privilege)                                   | Dropping client certs and shrinking the S3/IAM key surface reduce standing access to private keys.                        |
| FIPS 140-3             | Approved algorithms and key management                  | On-target minting constrained to FIPS-approved key types and SHA-2 digests supports the validated-module posture.         |
