# Proof of Concept — live e2e evidence

> Regenerated automatically by the AWS Deploy workflow on each proven MR.

**Provenance:** [workflow run](https://github.com/nwarila-platform/secure-wazuh/actions/runs/31321235888) · run `31321235888` · event `pull_request` · commit `082257f`
**Date:** 2026-08-09

## Phase 1 — initial deploy, fresh FIM proof

5/5 entries proven:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-206309901632893503883581629419177585700 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-268045757809368224919580979241005075080 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-146459590941358008490472332834597218052 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-268609256013580311652983278574471828723 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-62271281846447191449916179785705641382 |

## OS-swap — AIO OS-drive replacement

- Pre-swap AIO instance: `i-0dfe1d49c28b3af30`
- Post-swap AIO instance: `i-0f00fcdde0f371b28`
- Data volume: preserved and re-attached (not replaced)

## Phase 2 — cumulative validation after the swap

10/10 cumulative ledger entries proven (pre-swap survivors + new events) — agents reconnect after a manager OS rebuild AND data persists:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-206309901632893503883581629419177585700 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-268045757809368224919580979241005075080 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-146459590941358008490472332834597218052 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-268609256013580311652983278574471828723 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-62271281846447191449916179785705641382 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-302822575381129649659733559835252785870 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-240644633805729946275405767043796797663 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-221323962324718897646696155730919644083 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-10098288467046616628777995614494427839 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-328960046220318868671034189610490187668 |

## Teardown

This environment was destroyed successfully before this evidence was published
(`terraform destroy -auto-approve` — see this workflow's own
"Terraform destroy (always)" step).

## Cost

~$1 total, torn down automatically. $0 standing.
