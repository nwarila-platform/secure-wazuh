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
| `ENV` | str | Environment selector (`int`/`test`/`prod`); selects the `vars/redhat_<env>.yml` overlay. |
| `state` | str | `present` (default) or `clean`. Top-level per the loader contract (only `ENV`/`state` stay top-level). |
| `wazuh_server.secrets.admin_password` | str | The ONE operator-provided password (dashboard/OpenSearch `admin`). Everything else is generated or derived and rotated every run. |

Everything else lives in `defaults/main.yml` (S3 coordinates, ports, FIM realtime dirs, bind
mounts, service state). User overrides go in the `wazuh_server:` extra-var dict.

## Prerequisites

- The `/mnt/data` data disk mounted (step 0 — `linux_disk_manager`). The role binds the
  indexer/manager/dashboard state onto subdirectories of `/mnt/data/wazuh`; it does not
  partition or format raw disks.
- The bootstrap venv (`bootstrap.yml`) — the S3 download borrows its boto3.
- The offline bundle + cert PEMs in S3 at the keys pinned in the env overlay, each verified
  against a SHA-256 pin after download. See
  [`../../../docs/reference/s3-artifacts.md`](../../../docs/reference/s3-artifacts.md).

## Secrets and TLS

The operator supplies exactly one password. OpenSearch internal service users are generated
fresh each run and exist only as bcrypt hashes; the manager-API users are derived
deterministically from the admin password so reruns stay authenticatable without persisting
anything. TLS material is currently fetched from S3 and verified; the target two-tier PKI is
tracked in [ADR-0001](../../../docs/decision-records/repo/0001-secrets-and-tls.md).

## Example

```yaml
- hosts: 'wazuh_servers'
  roles:
    - role: 'wazuh_server'
      vars:
        ENV: 'int'
        state: 'present'
        wazuh_server:
          secrets:
            admin_password: "{{ wazuh_admin_password }}"
```
