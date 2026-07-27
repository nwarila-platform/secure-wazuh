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
- **The manager endpoint must be explicit.** `wazuh_agent` requires a non-empty
  `wazuh_agent.manager.host`; it never reads `wazuh_servers` or infers a manager from inventory
  topology. Stage 2 supplies that endpoint only after Step 0 has asserted exactly one manager.
- **The Linux agent installer rejects a manager/agent identity collision.** It compares the
  configured manager endpoint with the agent's `private_ip_address`, `ansible_host`, and
  `inventory_hostname`. It also requires a literal IPv4 enrollment address because DNS names are
  unsafe for the manager's anti-impersonation binding.

## Inventory groups

| Group | Membership | Execution |
|---|---|---|
| `wazuh_servers` | The single AIO host | `wazuh_server` (indexer + manager + Filebeat + dashboard) |
| `wazuh_agents` | All endpoint hosts (Linux and Windows) | `wazuh_agent` in Stage 2 |
| `wazuh_agents_linux` | Linux endpoint hosts only | Inline FIM trigger in Stage 3a |
| `wazuh_agents_windows` | Windows endpoint hosts only | Inline FIM trigger in Stage 3b |
| `wazuh_indexers`, `wazuh_dashboards` | Static-inventory compatibility aliases; omitted by the AWS dynamic inventory | None; the AIO role runs only from `wazuh_servers` |

`deploy-aws-poc.yml` bootstraps every host through `os_bootstrap`, deploys `wazuh_server` to
`wazuh_servers` (Stage 1), then deploys the all-agent `wazuh_agents` group through the normal
`wazuh_agent` role entry (Stage 2). The platform subsets target the inline Linux and Windows FIM
trigger plays in Stage 3.

### Minimal all-in-one inventory

The one host appears in the central groups. Each endpoint goes in `wazuh_agents` and its matching
platform subset:

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

wazuh_agents_linux:
  hosts:
    endpoint-01: {}
```

The permanent Proxmox target and the ephemeral AWS target use the same group names; only host
addresses and connection details differ between the two inventories.

## Naming and certificate coupling

The internal node identity defaults to the inventory hostname:

1. **Keep `ansible_host` set to the IP** unless the inventory FQDN resolves both from the controller and on the target itself. The role's reachability checks use `endpoint_host` (falling back to `ansible_host`, then the inventory name).
2. **`node_name` defaults to `inventory_hostname`.** Every run mints the internal node certificate with that name plus `localhost` and `127.0.0.1` in its SANs. Renaming the inventory host therefore rotates the OpenSearch identity automatically; set `wazuh_server.node_name` only when OpenSearch needs a stable explicit name.
3. **Internal TLS health checks use loopback.** Loopback is always in the minted node SANs. The dashboard login check validates the distinct S3-custodied listener certificate, whose SANs must cover the address used for that check.

## Related

- [`explanation/architecture.md`](../explanation/architecture.md) — what the AIO host contains and why it collapsed.
- [`reference/s3-artifacts.md`](s3-artifacts.md) — the dashboard listener pair and package objects
  held in S3.
- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — deploying against this topology.
