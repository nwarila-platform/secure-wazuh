# Proof of Concept — live e2e evidence

> Regenerated automatically by the AWS Deploy workflow on each proven MR.

**Provenance:** [workflow run](https://github.com/nwarila-platform/secure-wazuh/actions/runs/31317419285) · run `31317419285` · event `pull_request` · commit `cd60ec2`
**Date:** 2026-08-09

## Phase 1 — initial deploy, fresh FIM proof

5/5 entries proven:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-109492272932860864122991164777133385507 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-324781415632920639172316669162050167758 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-229793522663010395109264391039794816240 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-167540268925347104334003707661583996571 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-119028123413447794862721067245493902069 |

## OS-swap — AIO OS-drive replacement

- Pre-swap AIO instance: `i-07175bc230dfab123`
- Post-swap AIO instance: `i-0a0202c3f4323af33`
- Data volume: preserved and re-attached (not replaced)

## Phase 2 — cumulative validation after the swap

10/10 cumulative ledger entries proven (pre-swap survivors + new events) — agents reconnect after a manager OS rebuild AND data persists:

| Agent | Platform | Rule | Marker |
|---|---|---|---|
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-109492272932860864122991164777133385507 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-324781415632920639172316669162050167758 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-229793522663010395109264391039794816240 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-167540268925347104334003707661583996571 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-119028123413447794862721067245493902069 |
| sw-win-winrm | windows | 554 | fim-proof-sw-win-winrm-129467504795821854814030810994038268240 |
| sw-lin-ssm | linux | 550 | fim-proof-sw-lin-ssm-233456300635156089226512581353255654448 |
| sw-lin-ssh | linux | 550 | fim-proof-sw-lin-ssh-251521544372543220603050415382346960191 |
| sw-win-ssm | windows | 554 | fim-proof-sw-win-ssm-118942296434342040629534410238217905751 |
| sw-win-ssh | windows | 554 | fim-proof-sw-win-ssh-257639862385931510325869950958461454905 |

## Teardown

This environment was destroyed successfully before this evidence was published
(`terraform destroy -auto-approve` — see this workflow's own
"Terraform destroy (always)" step).

## Cost

~$1 total, torn down automatically. $0 standing.
