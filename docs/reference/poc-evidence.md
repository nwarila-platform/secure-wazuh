# Proof of Concept — live e2e evidence

> Evidence rendered by the AWS Deploy workflow; provenance identifies the triggering event.

**Provenance:** [workflow run](https://github.com/nwarila-platform/secure-wazuh/actions/runs/30165136898) · run `30165136898` · event `workflow_dispatch` · commit `63ffe48`
**Date:** 2026-07-25

## Additional runtime proof

[Run 30316886760](https://github.com/nwarila-platform/secure-wazuh/actions/runs/30316886760)
completed the two-phase path with:

- fresh on-target internal CA, indexer-node, securityadmin, and manager-API identities in each
  phase, with the CA key destroyed after issuance;
- the dashboard serving its configured S3-custodied listener certificate on 443;
- the guarded rung-3 `rbac.db` recovery marker present and checked; and
- FIM reaching realtime readiness in both phases.

## Phase 1 — initial deploy, fresh FIM proof

2/2 entries proven:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| secure-wazuh-poc-agent-linux | linux | 550 | fim-proof-secure-wazuh-poc-agent-linux-1747171383 |
| secure-wazuh-poc-agent-win | windows | 554 | fim-proof-secure-wazuh-poc-agent-win-8997570461 |

## OS-swap — AIO OS-drive replacement

- Pre-swap AIO instance: `i-07638186825242bc9`
- Post-swap AIO instance: `i-0bf4cfece64c4a49d`
- Data volume: preserved and re-attached (not replaced)

## Phase 2 — cumulative validation after the swap

4/4 cumulative ledger entries proven (pre-swap survivors + new events) — agents reconnect after a manager OS rebuild AND data persists:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| secure-wazuh-poc-agent-linux | linux | 554 | fim-proof-secure-wazuh-poc-agent-linux-1747171383 |
| secure-wazuh-poc-agent-win | windows | 554 | fim-proof-secure-wazuh-poc-agent-win-8997570461 |
| secure-wazuh-poc-agent-linux | linux | 550 | fim-proof-secure-wazuh-poc-agent-linux-1708358595 |
| secure-wazuh-poc-agent-win | windows | 554 | fim-proof-secure-wazuh-poc-agent-win-8390679596 |

## Teardown

This environment was destroyed successfully before this evidence was published
(`terraform destroy -auto-approve` — see this workflow's own
"Terraform destroy (always)" step).

## Cost

~$1 total, torn down automatically. $0 standing.
