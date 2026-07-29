# How to provide AWS credentials safely

**Type**: How-to (Diátaxis). For the objects involved, see
[`reference/s3-artifacts.md`](../reference/s3-artifacts.md); for the deployment flow, see
[`how-to/deploy-the-stack.md`](deploy-the-stack.md).

The controller assumes `secure-wazuh-artifact-reader` for each host immediately beside each
package-fetch attempt and keeps the resulting session in that host's controller-side variable
context. It signs one 900-second GetObject URL for that host and attempt, and the target performs a
plain HTTPS GET with no AWS SDK, deploy
credential, standalone artifact-reader credential, or instance-profile S3 grant. The URL is
itself a bearer token and necessarily contains the temporary access-key identifier and session
token as signing query parameters. It is not a reusable AWS credential set: it authorizes one
read-only object until expiry. Malware on the receiving host can nevertheless replay that URL
against that object during its lifetime.

The dashboard listener pair contains a private key and is deliberately not presigned. The
controller re-mints immediately before downloading those small files and pushes them through
Ansible. Internal PKI never transits S3.

## Why the target must never hold deploy or artifact-reader authority

Wazuh captures `sudo` command lines and process environments as alerts. A credential exported
into a target shell can therefore be indexed and retained. Module arguments are not a safe
substitute: `no_log` censors callback output but does not stop Ansible serializing those arguments
into a transient module payload.

The deploy keeps both the ambient identity and scoped artifact-reader sessions on the controller.
Targets receive only short-lived bearer URLs, and both signing and fetching are marked `no_log`.
Each target still has its SSM-only instance-profile credential available through instance
metadata. The boundary is that no deploy or reusable artifact-reader credential reaches the
target; the one-object bearer capability does.

## The pattern

1. **Step 0 validates the role input and the run-scoped hosts but mints nothing.** The guard uses
   the same server-plus-agent groups whose exact shape Step 0 already asserted. It requires every
   inventory instance ID to exist, carry one common `secure-wazuh-poc-profile`, and match the
   profile object being inspected. That profile must contain exactly `secure-wazuh-poc-role`;
   the role must have only the AWS-managed `AmazonSSMManagedInstanceCore` attachment and no inline
   policy, including the legacy `secure-wazuh-artifact-read` name. The guard also reads the
   artifact bucket policy and rejects any resource-based Allow for the instance role. A missing
   bucket policy is safe; an unreadable policy is a hard failure. Platform preparation, disk
   resolution, and host preparation consume no artifact credential or URL lifetime.

2. **Each package attempt assumes the reader role beside its use.** The composed framework's
   `applications/s3_artifact_delivery/tasks/mint_session.yml` at the commit named by
   `.github/.framework-pin` is the source of truth. It runs `amazon.aws.sts_assume_role` on
   delegated localhost under the ambient deploy identity and consumes the reader-role ARN,
   session name, and region supplied by the caller.

   Censored, non-cacheable facts hold the returned values in the current inventory host's
   controller-side variable context. The assume-role register is overwritten immediately after
   the copy; the three facts are overwritten in the attempt's `always` path.

3. **One local signing task creates a 900-second URL for the current attempt.** The custom module
   calls botocore's local SigV4 implementation with the controller fact values and performs no S3
   lookup. The secret key remains argument-spec `no_log`; the access-key identifier and session
   token deliberately do not, because Ansible would otherwise replace their occurrences inside
   the returned URL and corrupt the signature. The entire signing task remains `no_log`, and an
   immediate censored assertion rejects an empty URL or any redaction marker before the fetch.

4. **The immediately following target task fetches over HTTPS and verifies while downloading.**

   ```yaml
   - name: 'S3 | Fetch The Offline Bundle With A Fresh Signature Per Attempt'
     no_log: true
     vars:
       s3_artifact_delivery_reader_role_arn: >-
         {{ lookup('ansible.builtin.env', 'ARTIFACT_READER_ROLE_ARN') }}
       s3_artifact_delivery_session_name: >-
         secure-wazuh-server-bundle-{{ lookup('ansible.builtin.env', 'GITHUB_RUN_ID') }}
       s3_artifact_delivery_bucket: "{{ artifact_bucket }}"
       s3_artifact_delivery_object_key: "{{ bundle_object_key }}"
       s3_artifact_delivery_region: "{{ AWS_DEFAULT_REGION }}"
       s3_artifact_delivery_checksum: "{{ trusted_bundle_sha256 | lower | trim }}"
       s3_artifact_delivery_destination: "{{ bundle_path }}"
       s3_artifact_delivery_platform: 'posix'
     ansible.builtin.include_role:
       name: 's3_artifact_delivery'
       tasks_from: 'fetch'
   ```

   The helper runs up to three sequential mint-sign-fetch includes with two 10-second delays.
   A successful include prevents the later includes from expanding, so no later session or
   signature is created. The 60-second setting is a socket inactivity timeout, not a wall-clock
   transfer cap,
   so there is no finite transfer-time bound or derived expiry margin. Each attempt instead owns
   a fresh session and URL, and S3 evaluates that URL when its request begins. Linux bundle/RPM
   and Windows MSI digests all use `lower | trim`; both download modules explicitly use
   `force: false` and report the fetch unchanged. POSIX files land at mode `0600`; the Windows
   MSI receives an explicit protected ACL granting full control only to SYSTEM and built-in
   Administrators.

5. **The boundary is re-asserted immediately before the first fetch.** The server role repeats
   the instance-profile, exact-policy-set, and bucket-policy checks against the same run-scoped
   inventory IDs directly before artifact staging. This narrows, but cannot eliminate, the
   check/use race.

6. **The dashboard private key never becomes a bearer URL, and there is no fallback.** After the
   bundle fetch completes, one public `s3_artifact_delivery` `get` invocation mints a separate
   fresh session and retrieves the certificate, private key, and two sidecars into the guarded
   controller temp tree. The role scrubs its session and download state before `wazuh_server`
   pushes the files to root-only target staging. The live-profile guard has already rejected the
   legacy S3 policy. A URL cannot authorize more than
   `secure-wazuh-artifact-read`; if that role lacks GetObject on a key, the HTTPS request fails
   authorization rather than switching identities.

The scoped session values are not exported to a target environment, passed on a target command
line, or stored in the Ansible fact cache. `no_log` still does not prevent controller module
arguments from reaching transient disk. The GitHub workflows therefore set controller-local and
delegated-localhost transfer temp to
`${{ runner.temp }}/secure-wazuh-ansible/local`, outside the workspace, and remove the parent tree
with an `always()` step after every playbook invocation.

The URL serializes into the target fetch module payload and, on both platform modules, can appear
in the registered result or failure text. Task-level `no_log` is therefore load-bearing for
Ansible output. The URL fact and fetch/signing registers are overwritten in `always` immediately
after each attempt. Target task temp is transient and the 900-second expiry bounds any remnant's
value.

On the Windows STIG target, `win_get_url` runs through PowerShell while script-block logging and
transcription are required. Those target-owned controls can retain the module argument, including
the complete bearer URL, in the Windows event log beyond the URL's expiry; `no_log` does not
govern or erase that record. The expired record is not a reusable credential, but malware that
reads it before expiry can replay the one-object, read-only URL. This is a residual exposure, not
fixed by controller result scrubbing.

Targets retain their STIG-compatible `/opt/ansible/tmp` path. The only deploy-level target
`environment:` export is the non-secret `TMPDIR`, scoped to `wazuh_server` staging on `/mnt/data`;
`ENV` is an Ansible fact, not a shell environment variable.

## Procedure: populate the controller environment

The controller needs a deploy identity that can assume the artifact-reader role. In CI, use OIDC
role assumption; locally, use a role-backed profile. Do not print or pipe credential exports
through captured output.

The playbook takes no `--extra-vars`. Activate the deploy identity, export the two non-secret
artifact inputs, and run the command unchanged:

```bash
ansible_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/secure-wazuh-ansible.XXXXXX")"
export ANSIBLE_LOCAL_TEMP="${ansible_temp_root}/local"
mkdir -p "${ANSIBLE_LOCAL_TEMP}"
trap 'rm -rf -- "${ansible_temp_root}"' EXIT
export ANSIBLE_S3_BUCKET='your-org-artifact-bucket-name'
export ARTIFACT_READER_ROLE_ARN='arn:aws:iam::<account-id>:role/secure-wazuh-artifact-reader'
ansible-playbook -i inventory/aws/aws_ec2.yml playbooks/deploy-aws-poc.yml
```

GitHub workflows derive both non-secret values from their existing organization input. Each
`ansible-playbook` invocation performs fresh use-boundary assumptions; the two end-to-end phases
share no session or URL.

## Failure behavior

Signing, controller retrieval, and target fetches are censored because they handle a credential,
private key, or bearer URL. Each path rescues a hidden failure with a constant, secret-free
artifact label. It never prints caller-supplied object keys, the account-shaped bucket, scoped
session, or URL, and does not retry indefinitely or switch to instance metadata or another
credential chain.

## Related

- [`reference/s3-artifacts.md`](../reference/s3-artifacts.md) — object keys, hashes, and IAM scope.
- [`how-to/deploy-the-stack.md`](deploy-the-stack.md) — where the artifact flow sits in deployment.
- [`explanation/toolchain-rhel8.md`](../explanation/toolchain-rhel8.md) — why boto3 remains controller-side.
