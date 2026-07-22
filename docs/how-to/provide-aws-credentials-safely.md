# How to provide AWS credentials safely

**Type**: How-to (Diátaxis). For the objects these credentials read, see [`reference/s3-artifacts.md`](../reference/s3-artifacts.md); for how the deploy consumes them, see [`how-to/deploy-the-stack.md`](deploy-the-stack.md).

The S3 downloads (offline bundle, cert PEMs, Linux agent RPM) run **on the target host**, so the target's boto3 needs AWS credentials at module-call time — with one exception: the Windows agent MSI download is **controller-delegated** (a Windows target has no boto3), so it runs on the controller/runner instead. Either way, the safe way to supply the credentials is as `no_log` module arguments sourced from the runner environment — never as target (or controller) shell environment variables, and never echoed to stdout. This guide explains the pattern and how to follow it.

## Why the target shell must never hold the credentials

Wazuh captures `sudo` command lines as alerts. Every Ansible task that runs under `become` is a `sudo` invocation, and the process environment of that invocation is part of what the audit trail records. If AWS credentials are exported into the target shell environment, they land in `sudo`/audit-derived Wazuh alerts and are then indexed and retained.

This is not hypothetical: an access key leaked exactly this way and had to be rotated. The fix was to stop exporting credentials into the target environment and instead pass them directly to the S3 module as arguments, where they are marked `no_log`.

## The pattern

Three pieces work together:

1. **`playbooks/aws_runner_env.yml`** reads short-lived credentials from the **controller/runner** process environment and turns them into Ansible variables:

   ```yaml
   AWS_ACCESS_KEY_ID:     "{{ lookup('ansible.builtin.env', 'AWS_ACCESS_KEY_ID') }}"
   AWS_SECRET_ACCESS_KEY: "{{ lookup('ansible.builtin.env', 'AWS_SECRET_ACCESS_KEY') }}"
   AWS_SESSION_TOKEN:     "{{ lookup('ansible.builtin.env', 'AWS_SESSION_TOKEN') }}"
   AWS_DEFAULT_REGION:    "{{ lookup('ansible.builtin.env', 'AWS_DEFAULT_REGION') }}"
   ```

   Each stage in `site.yml` loads it via `vars_files`.

2. **The role's S3 block passes those variables as module arguments**, under a block that is marked `no_log: true`:

   ```yaml
   access_key:    "{{ AWS_ACCESS_KEY_ID | default(omit, true) }}"
   secret_key:    "{{ AWS_SECRET_ACCESS_KEY | default(omit, true) }}"
   session_token: "{{ AWS_SESSION_TOKEN | default(omit, true) }}"
   ```

   The credentials reach boto3 as in-process arguments. They are not written to the target's environment, not passed on a command line, and are censored from task output.

3. **The credentials never touch the target shell.** There is no `environment:` export of AWS keys onto the target. The only thing exported to the target shell is `ENV`.

## Procedure: populate the runner environment

Use short-lived credentials. In CI, prefer OIDC role assumption; locally, a role-backed profile is fine.

### In CI

Assume the deploy role via OIDC and let the standard AWS environment variables populate for the job. `aws_runner_env.yml` picks them up. Nothing further is needed.

### Locally, without echoing secrets to stdout

Any tooling that captures process stdout — including agent tool layers — will capture credentials if you pipe them through stdout. Do **not** run the credential export in a context whose output is captured.

Prefer writing the credentials to a protected vars file with direct file I/O, then pass it to `ansible-playbook`:

```bash
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml \
  -e env=int -e @/path/to/aws-vars.json
```

An interactive operator terminal that does not capture command output may `source` an export command directly; this is only unsafe when a tool layer records stdout into a transcript.

## Verification

Confirm no credential material reached the target:

```bash
# The S3 tasks should show "censored due to no_log" rather than any key material.
ansible-playbook -i inventory/proxmox.yml playbooks/site.yml -e env=int -v 2>&1 \
  | grep -i 'no_log' | head

# After a run, spot-check that no recent Wazuh alert contains AWS key patterns.
# Sudo-derived alerts should show only the ENV var and the interpreter path.
```

If an S3 download fails, the `no_log` block hides the underlying error. The role deliberately re-fails afterward with a **secret-free** message listing the expected bucket and object names, so a failed download stays diagnosable without exposing credentials.

## Related

- [`reference/s3-artifacts.md`](../reference/s3-artifacts.md) — the objects and IAM scope these credentials need.
- [`how-to/deploy-the-stack.md`](deploy-the-stack.md) — where credentials fit in the deploy flow.
- [`explanation/toolchain-rhel8.md`](../explanation/toolchain-rhel8.md) — why boto3 runs from a dedicated venv on the target.
