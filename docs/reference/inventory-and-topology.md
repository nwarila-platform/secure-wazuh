# Inventory and topology

**Type**: Reference (Diátaxis). For the reasoning behind the collapsed stack, see [`explanation/architecture.md`](../explanation/architecture.md). To deploy against this topology, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md).

This document states the supported topology and the inventory groups that drive it. It describes facts, not procedure.

## Supported topology: all-in-one only

The central stack is **collapsed**. OpenSearch indexer, Wazuh manager, Filebeat, and dashboard run as one role (`wazuh_server`) on **one host**. Every internal endpoint resolves to loopback:

| Setting | Value | Consumers |
|---|---|---|
| `indexer_host` | `127.0.0.1` | Filebeat, manager indexer-connector, dashboard `opensearch.hosts` |
| `manager_host` | `127.0.0.1` | dashboard `wazuh.yml` manager API |
| `discovery_seed_hosts` | `[]` | OpenSearch discovery |

Split-host topology (indexer, manager, and dashboard on separate hosts) is **intentionally not supported**. The role defaults hard-code local endpoints, and the OpenSearch security config lists only this host's distinguished name under `nodes_dn`.

## Fail-fast behavior

The roles refuse configurations they cannot serve correctly rather than deploying something broken:

- **Multi-node indexer clustering is not configured.** A multi-node cluster would require every peer node's DN under `plugins.security.nodes_dn`; the template lists only the local node, so the stack is single-node by construction. Do not add peers to `wazuh_servers` expecting them to cluster.
- **The agent role refuses to run on a manager host.** `wazuh_agent` asserts that `inventory_hostname` is **not** in `groups['wazuh_servers']` and stops with a clear message. The manager owns `/var/ossec` and already runs on-box monitoring as agent `000`; installing the standalone agent package on top of it is a conflict. Use a separate endpoint host for standalone agent validation.
- **The agent requires a resolvable manager and an IPv4 enrollment address.** It asserts a manager endpoint is known (from `wazuh_agent.manager.host` or the first host in `wazuh_servers`) and that the enrollment address is a literal IPv4 — DNS names are rejected because they are unsafe for the manager's anti-impersonation binding.

## Inventory groups

| Group | Membership | Role that runs on it |
|---|---|---|
| `wazuh_servers` | The single AIO host | `wazuh_server` (indexer + manager + Filebeat + dashboard) |
| `wazuh_agents` | Linux endpoint hosts only | `wazuh_agent` |
| `wazuh_agents_windows` | Windows endpoint hosts only | `wazuh_agent`, via its native Windows entry point (`tasks/main_windows.yml`, bypassing the Linux-only loader) |
| `wazuh_indexers`, `wazuh_dashboards` | The same AIO host | Present for inventory clarity and Terraform-generated grouping; the AIO role runs off `wazuh_servers` |

`site.yml` deploys `wazuh_server` to `wazuh_servers`, then `wazuh_agent` to `wazuh_agents` if that group has hosts, then (Stage 3) `wazuh_agent` to `wazuh_agents_windows` if that group has hosts.

### Minimal all-in-one inventory

The one host appears in the central groups; endpoints go in `wazuh_agents`:

```yaml
wazuh_servers:
  hosts:
    wazuh-aio:
      ansible_host: 10.69.112.72
      ansible_user: ansible_admin

wazuh_agents:
  hosts:
    endpoint-01:
      ansible_host: 10.69.112.80
      ansible_user: ansible_admin
```

The permanent Proxmox target and the ephemeral AWS target use the same group names; only host addresses and connection details differ between the two inventories.

## Naming and certificate coupling

Three things key off the inventory hostname, so change them together:

1. **Keep `ansible_host` set to the IP** unless the inventory FQDN resolves both from the controller and on the target itself. The role's on-target reachability and TLS-validated health checks use `endpoint_host` (falling back to `ansible_host`, then the inventory name).
2. **Cert object names follow `cert_name`, which defaults to `inventory_hostname`.** Renaming the host makes the role fetch PEMs under the new name. Either upload PEMs under the new name (with the FQDN in the SANs) or pin `wazuh_server.cert_name` to the original name the PEMs carry.
3. **Health checks validate certificates.** Whatever host the checks dial must appear in the node cert's SANs. Loopback (`127.0.0.1`) is always in the SANs, so the login smoke test never trips on a missing external-IP SAN.

## Related

- [`explanation/architecture.md`](../explanation/architecture.md) — what the AIO host contains and why it collapsed.
- [`reference/s3-artifacts.md`](s3-artifacts.md) — cert object names derived from `cert_name`.
- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — deploying against this topology.
