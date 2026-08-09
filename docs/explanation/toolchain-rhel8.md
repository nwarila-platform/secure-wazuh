# Toolchain: why it is pinned to the RHEL 8 line

**Type**: Explanation (Diátaxis). For the deploy that runs on this toolchain, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md).

secure-wazuh pins a deliberately old Ansible toolchain: `ansible-core >=2.16,<2.17`, `community.general <8`, `ansible.posix <2`, and `ansible-lint 24.x`. These ceilings are not neglect. They are the last releases that can still manage a RHEL/Rocky 8 target. Controller-only AWS operations use the controller's modern Python without changing that target interpreter.

## The root cause: platform-python 3.6.8

RHEL/Rocky 8 ships **platform-python 3.6.8** as the interpreter that carries the `libselinux`, `dnf`, and `firewalld` C bindings the roles depend on. Those bindings are what let `ansible.builtin.dnf`, SELinux-aware `ansible.builtin.file`, and `ansible.posix.firewalld` work at all on the target. There is no `python3.12-libselinux`, `python3.12-dnf`, or `python3.12-firewall` package in AppStream or EPEL — the C bindings exist only for platform-python. So on a RHEL 8 target, platform-python 3.6 is the interpreter Ansible must dispatch modules through.

## The breakage: `from __future__ import annotations`

Modern Ansible assets emit `from __future__ import annotations`, a Python 3.7+ construct. On Python 3.6 that line raises:

```text
SyntaxError: future feature annotations is not defined
```

Any collection or ansible-core release that ships those future-annotations imports will `SyntaxError` the moment its module code is executed under platform-python 3.6. That rules out:

- **`ansible-core >=2.17`** — it (and `ansible-lint >=25`) require 2.17+ and emit future-annotations, so they cannot manage a 3.6 target. The controller `ansible-core` must stay on the last line that still can: **2.16.x**.
- **`community.general >=8`** — 8.x and later use future-annotations and break on 3.6. `community.general` supplies the `parted` and `filesystem` modules used by the step-0 `linux_disk_manager` storage initializer, so it must stay `<8`.
- **`ansible.posix >=2`** — 2.x uses future-annotations and breaks on 3.6. `ansible.posix` supplies `firewalld` and mount/SELinux helpers the roles use, so it must stay `<2`.

`ansible-lint` is held at 24.x to match: 24.x supports ansible-core 2.16, 25.x needs 2.17+.

## The controller boundary for boto3

RHEL 8 platform-python cannot run the boto3/botocore floor required by the pinned `amazon.aws`
collection. The deploy therefore runs every AWS SDK operation on the controller:

- dynamic EC2 inventory;
- artifact-reader role assumption;
- local SigV4 presigning and dashboard-listener retrieval; and
- the controller-delegated EBS Function-tag resolver.

Linux package artifacts arrive through `ansible.builtin.get_url`; Windows uses
`ansible.windows.win_get_url`. Both perform ordinary HTTPS GETs against a short-lived URL, with
the trusted SHA-256 supplied to the download module. The dashboard listener pair is too sensitive
for a bearer URL, so the controller retrieves and pushes those small files. No target installs
boto3, botocore, `amazon.aws`, Python 3.12, or `/opt/ansible/venv`.

## Consequences

- **Do not bump these pins to "current".** An upgrade to ansible-core 2.17+, `community.general` 8+, or `ansible.posix` 2+ will pass on a modern controller and then `SyntaxError` against the RHEL 8 fleet. The pins move only when the target OS floor moves off RHEL 8.
- **The controller version matters, not just the collections.** `ansible-core` is a controller install, so it is pinned in `requirements-dev.txt`, while the runtime collections are pinned in `ansible/requirements.yml`.
- **The target interpreter stays distribution-owned.** Making a modern interpreter the default
  would still break the C-binding modules; keeping AWS work controller-side removes the need for
  an alternate target interpreter entirely.

## Related

- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — installing the controller toolchain and running the deploy.
- [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md) — the controller-only artifact-reader and signing flow.
- [`explanation/architecture.md`](architecture.md) — where S3 downloads sit in the install flow.
