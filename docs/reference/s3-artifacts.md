# S3 artifacts

**Type**: Reference (Diátaxis). To use these artifacts in a deploy, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md); for safe credential handling, see [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md).

S3 is the source of truth for package and certificate artifacts. The Linux roles download them **on the target host** through `amazon.aws.s3_object`; the Windows agent path is the exception — its MSI download is **controller-delegated** (see "Objects the agent role reads" below). This document catalogues the objects, their SHA-256 pins, and how the bucket is named.

## Bucket naming

The bucket is pinned per environment in each role's overlay at `s3.bucket` (`ansible/applications/<role>/vars/redhat_<env>.yml`). The org convention is an account- or org-scoped `*-ansible` bucket per environment. The current `int` value is:

| Setting | `int` value |
|---|---|
| `s3.bucket` | `<account-id>-ansible` |

Override `s3.bucket` in the per-env overlay (or the playbook `wazuh_server:` / `wazuh_agent:` dict) for other environments.

## Objects the AIO server role reads

The `wazuh_server` role downloads one offline bundle and a fixed set of cert PEMs:

| Object | Overlay key | Notes |
|---|---|---|
| Offline bundle | `s3.bundle_key` | `functions/wazuh/4.14.5/wazuh-offline.tar.gz` (int). Contains the indexer, manager, dashboard RPMs plus Filebeat module and template. |
| `root-ca.pem` | under `s3.certs_prefix` | Cluster CA public cert. |
| `admin.pem`, `admin-key.pem` | under `s3.certs_prefix` | OpenSearch admin client cert and key (used for securityadmin and the manager indexer-connector). |
| `<cert_name>.pem`, `<cert_name>-key.pem` | under `s3.certs_prefix` | The node cert and key. `cert_name` defaults to `inventory_hostname`. This is the public dashboard/indexer node certificate served on 443/9200. |

Current `int` cert prefix:

| Setting | `int` value |
|---|---|
| `s3.certs_prefix` | `functions/wazuh/certs` |

The role does **not** read `.sha256` sidecar objects for cert PEMs. Cert integrity relies on S3 IAM scope, boto3 transfer checksums, and S3-native `ChecksumSHA256` metadata when present.

## Objects the agent role reads

The `wazuh_agent` role does **not** unpack the central bundle. It downloads exactly one
standalone package per platform:

| Object | Overlay key | `int` value |
|---|---|---|
| Standalone agent RPM (Linux) | `s3.agent_rpm_key` | `applications/wazuh-agent/wazuh-agent-4.14.5-1.x86_64.rpm` |
| Standalone agent MSI (Windows) | `s3.agent_msi_key` | `applications/wazuh-agent/wazuh-agent-4.14.5-1.msi` |

The RPM downloads **on the target host** like the server role's objects. The MSI download is
**controller-delegated**: a Windows target has no boto3, so `tasks/main_windows.yml` runs
`amazon.aws.s3_object` with `delegate_to: localhost` against the controller/runner venv's
boto3 (the same AWS creds, passed as `no_log` module args), then `win_copy` pushes the
SHA-256-verified MSI to the Windows target.

## SHA-256 pins

Package artifacts are verified against a PR-reviewed known-good hash after download. A mismatch aborts the install (it means the object was tampered with or the wrong artifact was uploaded).

| Pin | Overlay key | Applies to |
|---|---|---|
| Bundle hash | `s3.bundle_sha256` | The downloaded `wazuh-offline.tar.gz` (server role). Current `int`: `1a60b8c407a56ed45a1e431256f6c49cba083a329874be7b532ec48a56069bea`. |
| Agent RPM hash | `s3.agent_rpm_sha256` | The downloaded agent RPM (Linux agent role). The agent role additionally asserts this is a real 64-character hex value before downloading. |
| Agent MSI hash | `s3.agent_msi_sha256` | The downloaded agent MSI (Windows agent role). Same real-64-character-hex assertion, checked in `present_windows.yml` before the controller-delegated download. |

When you re-upload an artifact, recompute the hash with `sha256sum` and update the matching overlay key in the same PR.

## Object layout summary

```text
s3://<bucket>/<bundle_key>                          # wazuh-offline.tar.gz  (server role)
s3://<bucket>/<certs_prefix>/root-ca.pem            # server role
s3://<bucket>/<certs_prefix>/admin.pem              # server role
s3://<bucket>/<certs_prefix>/admin-key.pem          # server role
s3://<bucket>/<certs_prefix>/<cert_name>.pem        # server role (public node/dashboard cert)
s3://<bucket>/<certs_prefix>/<cert_name>-key.pem    # server role
s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.x86_64.rpm   # agent role (Linux)
s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.msi         # agent role (Windows)
```

## IAM scope

Grant the deploy job S3 read on exactly what the role it runs needs:

- **AIO server job**: read `s3://<bucket>/<bundle_key>` and `s3://<bucket>/<certs_prefix>/*.pem`.
- **Agent job (Linux)**: read `s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.x86_64.rpm`.
- **Agent job (Windows)**: read `s3://<bucket>/applications/wazuh-agent/wazuh-agent-<version>-1.msi` — granted to the CONTROLLER identity, since the download is delegated there, not to the Windows target.

For stricter separation, only the indexer/server deploy job needs `admin-key.pem`; endpoint jobs never read it. If a job also publishes artifacts, it additionally needs S3 write on those same prefixes.

## Related

- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — the deploy that consumes these objects.
- [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md) — supplying the credentials that read them.
- [`reference/inventory-and-topology.md`](inventory-and-topology.md) — how `cert_name` derives from the inventory hostname.
