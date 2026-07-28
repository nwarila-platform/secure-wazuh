# wazuh_server

The **collapsed all-in-one central role**. On one host it installs and configures the entire
Wazuh 4.14.5 central stack from the offline bundle, in an explicit, load-bearing order:

| Component | Role owns |
|---|---|
| OpenSearch **indexer** | data + state indices, security init, the cluster-green gate |
| Wazuh **manager** | agent comms, detection rules, manager API, the realtime FIM stanza |
| **Filebeat** | ships `alerts.json` into the indexer |
| Wazuh **dashboard** | the OpenSearch-Dashboards web UI on 443 |

Everything internal resolves over loopback, so there is no split-host plumbing. The earlier
`wazuh_indexer` / `wazuh_dashboard` roles were folded into this one — see
[`../../../docs/explanation/architecture.md`](../../../docs/explanation/architecture.md) for why.
The endpoint `wazuh_agent` role is separate and does not consume the central bundle.

## Required inputs

| Variable | Type | Description |
|---|---|---|
| `ENV` | str | Environment selector (`dev`/`test`/`prod`); selects the `vars/redhat_<env>.yml` overlay. |
| `state` | str | `present` (default) or `clean`. Top-level per the loader contract (only `ENV`/`state` stay top-level). |
| `wazuh_server.secrets.admin_password` | str | The ONE resolved password input (dashboard/OpenSearch `admin`). The playbook normally mints it per invocation; everything else is generated or derived and rotated every run. |
| `wazuh_server.s3.bucket` | str | Artifact bucket supplied by the deployment. Empty values and the committed `<account-id>` tripwire fail during role validation. |

Everything else lives in `defaults/main.yml` (S3 coordinates, ports, FIM realtime dirs, bind
mounts, service state). User overrides go in the `wazuh_server:` extra-var dict.

## Prerequisites

- The `/mnt/data` data disk mounted (step 0 — `linux_disk_manager`). The role binds the
  indexer/manager/dashboard state onto subdirectories of `/mnt/data/wazuh`; it does not
  partition or format raw disks.
- The bootstrap venv (`deploy-aws-poc.yml`'s Linux Bootstrap section) — the S3 download borrows its boto3.
- The offline bundle plus `dashboard.pem` / `dashboard-key.pem` and their SHA-256 sidecars in S3
  at the keys pinned in the env overlay. See
  [`../../../docs/reference/s3-artifacts.md`](../../../docs/reference/s3-artifacts.md).

## Secrets and TLS

The playbook resolves exactly one admin password per invocation, normally minting it when no
explicit environment override is supplied. OpenSearch internal service users are generated fresh
each run and exist only as bcrypt hashes; manager-API users are derived from that invocation's
admin password, with guarded `rbac.db` recovery when prior state holds another value. Every run
mints an RSA-3072/SHA-256 internal CA and separate indexer-node, securityadmin, and manager-API
certificates on the target, then shreds the CA key after issuance. Filebeat, the manager indexer
connector, and the dashboard backend authenticate from their keystores and verify the internal CA;
internal PKI never transits S3. The separate dashboard 443 listener pair and sidecars are the only
certificate material S3 holds, making its listener key the single externally-custodied private key.
See [ADR-0001](../../../docs/decision-records/repo/0001-secrets-and-tls.md).

## Example

```yaml
- hosts: 'wazuh_servers'
  roles:
    - role: 'wazuh_server'
      vars:
        ENV: 'dev'
        state: 'present'
        wazuh_server:
          secrets:
            admin_password: "{{ wazuh_admin_password }}"
```
