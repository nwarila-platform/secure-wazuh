# Proof of Concept — live e2e evidence

> Regenerated automatically by the AWS Deploy workflow on each proven MR.

**Provenance:** [workflow run](https://github.com/nwarila-platform/secure-wazuh/actions/runs/31319282728) · run `31319282728` · event `pull_request` · commit `24a55f7`
**Date:** 2026-08-09

## Phase 1 — initial deploy, fresh FIM proof

5/5 entries proven:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-144407484966123969592296150559469579660 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-218162435332240226770511970793062923296 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-217241780369347012693912827567013836482 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-211785347771304508382805705217520202598 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-23087813454079166455344075273958634458 |

## OS-swap — AIO OS-drive replacement

- Pre-swap AIO instance: `i-0f81ed35f172480a5`
- Post-swap AIO instance: `i-00d481e670cf77c3d`
- Data volume: preserved and re-attached (not replaced)

## Phase 2 — cumulative validation after the swap

10/10 cumulative ledger entries proven (pre-swap survivors + new events) — agents reconnect after a manager OS rebuild AND data persists:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-144407484966123969592296150559469579660 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-218162435332240226770511970793062923296 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-217241780369347012693912827567013836482 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-211785347771304508382805705217520202598 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-23087813454079166455344075273958634458 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-123334848349819859354159368556276179001 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-140491370763147931435295600569217541394 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-266030154184968455537617439289594571376 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-202011833229386478686950208288146185723 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-334056299821115401537547335874736197289 |

## Teardown

This environment was destroyed successfully before this evidence was published
(`terraform destroy -auto-approve` — see this workflow's own
"Terraform destroy (always)" step).

## Cost

~$1 total, torn down automatically. $0 standing.
