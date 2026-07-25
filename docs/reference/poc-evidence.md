# Proof of Concept — live e2e evidence

> Regenerated automatically by the e2e-full workflow on each proven MR.

**Provenance:** local harness run, pre-CI-wiring, 2026-07-24 · [`e2e-full.yml`](../../.github/workflows/e2e-full.yml) two-phase deploy / OS-swap / destroy
**Date:** 2026-07-24

## Phase 1 — initial deploy, fresh FIM proof

2/2 entries proven:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| secure-wazuh-poc-agent-linux | linux | 554 (agent id 001) | `fim-proof-secure-wazuh-poc-agent-linux-<random>` |
| secure-wazuh-poc-agent-win | windows | 554 (agent id 003) | `fim-proof-secure-wazuh-poc-agent-win-<random>` |

## OS-swap — AIO OS-drive replacement

- Pre-swap AIO instance: `i-0b29a5ba327a90496`
- Post-swap AIO instance: `i-04e5172c8d69a3c26`
- Data volume: preserved and re-attached (not replaced) — a separate `aws_ebs_volume` resource
  from the `aws_instance` `refresh_serial` forces replacement of; `terraform apply -var
  refresh_serial=1` rebuilds the AIO's OS from `ami` fresh, but never touches its data disk.

## Phase 2 — cumulative validation after the swap

4/4 cumulative ledger entries proven (2 pre-swap survivors + 2 new events) — agents reconnect
after a manager OS rebuild AND data persists:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| secure-wazuh-poc-agent-linux | linux | 554 (agent id 001) | `fim-proof-secure-wazuh-poc-agent-linux-<random>` (phase 1, survivor) |
| secure-wazuh-poc-agent-win | windows | 554 (agent id 003) | `fim-proof-secure-wazuh-poc-agent-win-<random>` (phase 1, survivor) |
| secure-wazuh-poc-agent-linux | linux | 554 (agent id 001) | `fim-proof-secure-wazuh-poc-agent-linux-<random>` (phase 2, new) |
| secure-wazuh-poc-agent-win | windows | 554 (agent id 003) | `fim-proof-secure-wazuh-poc-agent-win-<random>` (phase 2, new) |

Rule 554 = "File added to the system" — every trigger writes a brand-new, uniquely-named file
(no Date/epoch, random suffix only), so each event is 554, never 550 ("Integrity checksum
changed", which would require modifying an already-monitored file instead).

## Teardown

11/11 resources destroyed (`terraform destroy -auto-approve`, unconditional — 3 instances, 3
ENIs, the AIO's data volume, 3 root volumes, and the managed per-system security group).

## Cost

~$1 total, torn down automatically. $0 standing.
