# Toolchain: why it is pinned to the RHEL 8 line

**Type**: Explanation (Diátaxis). For the deploy that runs on this toolchain, see [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md).

secure-wazuh pins a deliberately old Ansible toolchain: `ansible-core >=2.16,<2.17`, `community.general <8`, `ansible.posix <2`, and `ansible-lint 24.x`. These ceilings are not neglect. They are the last releases that can still manage a RHEL/Rocky 8 target. This document explains the constraint and how the bootstrap venv works around the one place it would otherwise bite.

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

## The exception: boto3 for S3 needs a newer Python

There is one thing the RHEL 8 platform-python cannot do: run the boto3/botocore floor that the current `amazon.aws` collection requires. That floor is above what platform-python 3.6 can install. But the S3 downloads run **on the target**, so the target needs a modern boto3 somewhere.

The resolution is a dedicated interpreter used **only** for the S3 tasks:

1. `bootstrap.yml` installs `python3.12` (available in AppStream) and builds `/opt/ansible/venv` with `--system-site-packages`, then pip-installs a fresh boto3/botocore into it. On STIG hosts it also adds the venv tree to fapolicyd trust.
2. The venv is **not** the default interpreter. `ansible.cfg` leaves `interpreter_python` on auto-discovery so ordinary modules keep landing on platform-python and its C bindings.
3. Only the `amazon.aws.s3_object` tasks override `ansible_python_interpreter` to the venv, at block level. That is the sole place the modern Python is used.

This gives module dispatch a modern boto3 for the two things that need it — the bundle/cert download in the server role and the RPM download in the agent role — without breaking `dnf`, SELinux, or `firewalld`, which stay on platform-python. Each role's install path asserts the venv exists (`BEGIN | Assert Bootstrap Venv Is Present`) so a host that skipped bootstrap fails loudly rather than mysteriously.

## Consequences

- **Do not bump these pins to "current".** An upgrade to ansible-core 2.17+, `community.general` 8+, or `ansible.posix` 2+ will pass on a modern controller and then `SyntaxError` against the RHEL 8 fleet. The pins move only when the target OS floor moves off RHEL 8.
- **The controller version matters, not just the collections.** `ansible-core` is a controller install, so it is pinned in `requirements-dev.txt`, while the runtime collections are pinned in `ansible/requirements.yml`.
- **The venv is scoped, not global.** Making it the default interpreter was tried and failed exactly because of the missing 3.12 C bindings; keep it confined to the S3 tasks.

## Related

- [`how-to/deploy-the-stack.md`](../how-to/deploy-the-stack.md) — installing the controller toolchain and running the bootstrap.
- [`how-to/provide-aws-credentials-safely.md`](../how-to/provide-aws-credentials-safely.md) — the S3 tasks that use the venv's boto3.
- [`explanation/architecture.md`](architecture.md) — where S3 downloads sit in the install flow.
