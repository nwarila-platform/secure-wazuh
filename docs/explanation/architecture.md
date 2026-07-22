# Architecture

**Type**: Explanation (Diátaxis). For the topology facts, see [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md); for how the code that runs this is assembled, see [`explanation/composition-model.md`](composition-model.md).

This document explains *what* secure-wazuh deploys and *why* the central stack collapsed into a single host and a single role.

## The collapsed all-in-one

secure-wazuh delivers a STIG- and FIPS-hardened Wazuh 4.14.5 SIEM. The central stack is four components that were historically separate roles:

- **OpenSearch indexer** — stores and searches alerts (`wazuh-alerts-*`) and state indices.
- **Wazuh manager** — receives agent events, runs detection rules, and hosts the manager API.
- **Filebeat** — ships the manager's `alerts.json` into the indexer.
- **Wazuh dashboard** — the OpenSearch-Dashboards-based web UI on 443.

In the current design these run **on one host, as one role** (`wazuh_server`). Endpoint agents remain a separate role (`wazuh_agent`) that installs on endpoint hosts only.

### Why collapse

The four components on an all-in-one box only ever talk to each other over loopback. Splitting them into four roles meant four S3 download blocks, four cert-fetch flows, four sets of endpoint plumbing, and cross-role ordering (indexer green before Filebeat starts) expressed across playbook boundaries. Collapsing them into one monolithic `present_redhat.yml` makes the load-bearing install order explicit and local:

```text
00 guards -> 01 secrets -> 02 host prep -> 03 S3 (one deduped block)
-> 04 package install (4 RPMs from one bundle) -> 05 indexer config + CLUSTER-GREEN GATE
-> 06 manager + Filebeat config (owned FIM stanza) -> 07 manager validation
-> 08 dashboard config -> 09 dashboard validation -> 10 FIM realtime verify
```

Everything internal resolves to `127.0.0.1`, so there is no group dereferencing and no split-host endpoint configuration to keep consistent. Split-host topology is intentionally dropped rather than carried as dead complexity — see [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md).

## Component roles

| Role | Runs on | Owns |
|---|---|---|
| `wazuh_server` | `wazuh_servers` (one host) | Indexer + manager + Filebeat + dashboard |
| `wazuh_agent` | `wazuh_agents` (endpoints) | Standalone agent install and enrollment |
| `linux_disk_manager` | `wazuh_servers` (step 0) | Provisioning and mounting the data volume |

`linux_disk_manager` is a shared framework role, not a product role — it is composed in from the pinned `ansible-framework` at run time (see [`explanation/composition-model.md`](composition-model.md)).

## Persistent data at `/mnt/data`

All component state lives on a persistent data volume mounted at `/mnt/data`, under `data_root = /mnt/data/wazuh`. The role binds the canonical service paths onto subdirectories of that volume:

| Canonical path | Bind subpath |
|---|---|
| `/var/lib/wazuh-indexer` | `indexer/data` |
| `/var/log/wazuh-indexer` | `indexer/logs` |
| `/var/ossec` | `server/ossec` |
| `/var/log/filebeat` | `server/filebeat-logs` |
| `/var/lib/wazuh-dashboard` | `dashboard/data` |
| `/var/log/wazuh-dashboard` | `dashboard/logs` |

This keeps indexer data, manager state, and dashboard state on the durable disk so a host OS rebuild can reattach the same volume without losing SIEM data. The role **assumes the volume is already mounted** — it creates and bind-mounts subdirectories but does not partition, format, or mount raw disks. That is the step-0 responsibility of `linux_disk_manager`, which selects the disk by stable WWN (never `/dev/sdX`) and mounts by UUID.

## Trust and hardening posture

- **Artifacts are verified before use.** The offline bundle and agent RPM are checked against PR-reviewed SHA-256 pins after download; a mismatch aborts the install.
- **Secrets rotate every run.** The operator supplies exactly one password (the `admin` superuser / dashboard login). Every OpenSearch internal service user is generated fresh each run and exists only as a bcrypt hash; the manager API users are derived deterministically from the admin password so reruns stay authenticatable without persisting anything.
- **Minimal external surface.** The indexer HTTP API (9200) is deliberately not opened in the firewall — on an AIO box every consumer reaches it over loopback. Only agent comms (1514), enrollment (1515), the manager API (55000), and the dashboard (443) are exposed.
- **File integrity monitoring is realtime.** The role replaces the vendor's 12-hour scheduled scan with an inotify realtime `<syscheck>` stanza on `/etc`, `/usr/bin`, `/usr/sbin`, so changes emit events immediately rather than only surfacing as periodic inventory diffs.

## External dependencies

- **S3** — the source of truth for the offline bundle, cert PEMs, and the agent RPM. Downloads run on the target; see [`reference/s3-artifacts.md`](../reference/s3-artifacts.md).
- **The pinned Ansible and Terraform frameworks** — the loader, shared roles, and all Terraform resource logic are composed in at run time from pinned framework commits; see [`explanation/composition-model.md`](composition-model.md).

## Related

- [`reference/inventory-and-topology.md`](../reference/inventory-and-topology.md) — the supported topology.
- [`explanation/composition-model.md`](composition-model.md) — how the runnable tree is assembled.
- [`explanation/toolchain-rhel8.md`](toolchain-rhel8.md) — why the toolchain is pinned to the RHEL 8 line.
