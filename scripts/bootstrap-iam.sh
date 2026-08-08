#!/usr/bin/env bash
# =========================================================================================== #
# bootstrap-iam.sh — materialize and apply this repository's AWS IAM
# ------------------------------------------------------------------------------------------- #
#   ./scripts/bootstrap-iam.sh [--apply|--check-drift] [aws-profile]
#
# Without a flag it PLANS: materializes, gates, validates every document through Access Analyzer,
# and prints what would be created or updated. Nothing is written to AWS.
#
# WHY A SCRIPT AND NOT A HAND-TYPED `aws iam create-policy-version`
#
# On 2026-08-03 a hand-typed apply put the literal token `<region>` into `aws:RequestedRegion` on
# the discovery policy. No region equals the string "<region>", so every ec2:Describe* fell to an
# implicit deny and `terraform apply` died 47 seconds in, unable to read an AMI. Reading the applied
# document back and diffing it against the tracked source PASSED — the source contains `<region>`
# by design, so a template compared against a target rendered from that template cannot detect an
# unrendered template. The substitution gate below is the only check that catches it, and the only
# way to guarantee it runs is to make the gated path the apply path. See ADR-0006.
#
# --check-drift compares LIVE IAM against the tracked source, INCLUDING ATTACHMENT. That is the
# comparison neither other gate makes: check-iam-literals.sh reads source vs filesystem and
# test-iam-policies.sh materializes FROM source, so both pass while live holds an older version —
# or while the policy is attached to nothing at all. The latter is not hypothetical: the retired
# `_deploy-ec2` policy sat detached for five days on 2026-07-29..08-03, verifying clean the whole
# time, while the launch policy that was actually attached still pinned a retired key pair.
#
# Substitution values are resolved from the live account and the live GitHub repository, never
# hand-typed. A key pair is NOT created here — it carries private key material whose custody is an
# operator decision.
# =========================================================================================== #
set -uo pipefail

APPLY=false; DRIFT=false
case "${1:-}" in
    --apply) APPLY=true; shift ;;
    --check-drift) DRIFT=true; shift ;;
esac
PROFILE="${1:-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${ROOT}/docs/reference/aws-iam"
OWNER='nwarila-platform'
REPO='secure-wazuh'

# The shared EC2 identity and key pair are ORG-WIDE objects, not per-repository ones. They are
# written literally rather than computed from ${REPO}: a computed "${REPO}-poc-key" is exactly the
# straggler that survived the 2026-08-03 unified-key cutover in this repo's test script and still
# survives in windows-wsus's copy of THIS file, where it silently materializes the retired name.
EC2_ROLE='nwarila-ec2-role'
EC2_PROFILE='nwarila-ec2-profile'
KEY_PAIR='nwarila-ec2-key'

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
say() { printf '  %-56s %s\n' "$1" "$2"; }
die() { printf 'bootstrap-iam: FAIL — %s\n' "$1" >&2; exit 1; }

echo "== resolving substitution values from live sources =="
ACCOUNT="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)" || die 'no AWS identity'
REPO_ID="$(gh api "repos/${OWNER}/${REPO}" --jq .id)" || die "GitHub repo ${OWNER}/${REPO} not found"
KMS_KEY="$(aws kms describe-key --key-id alias/aws/ebs --profile "${PROFILE}" --region "${REGION}" \
           --query 'KeyMetadata.KeyId' --output text)" || die 'alias/aws/ebs unresolved'
VPC_ID="$(aws ec2 describe-vpcs --profile "${PROFILE}" --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets --profile "${PROFILE}" --region "${REGION}" --query 'Subnets[0].SubnetId' --output text)"
# The OIDC subject GitHub actually emits embeds the OWNER id as well as the repository id, so the
# CI trust accepts both spellings of `sub`. Resolve the owner id rather than hard-coding it — and
# never drop the id-embedded form: narrowing `sub` back to the plain spelling makes the deploy role
# unassumable by the very workflow it exists for, with no error visible until a run fails at OIDC.
OWNER_ID="$(gh api "orgs/${OWNER}" --jq .id)" || die "cannot resolve owner id for ${OWNER}"
say 'repository id' "${REPO_ID}"
say 'vpc / subnet' "${VPC_ID} / ${SUBNET_ID}"
say 'key pair (referenced, never created)' "${KEY_PAIR}"

echo "== materialize =="
mkdir -p "${WORK}/policies" "${WORK}/roles"
cp "${IAM_DIR}/policies/"*.json "${WORK}/policies/"
cp "${IAM_DIR}/roles/"*.json    "${WORK}/roles/"
sed -i "s|<account-id>|${ACCOUNT}|g; s|<repository-id>|${REPO_ID}|g; s|<region>|${REGION}|g;
        s|<vpc-id>|${VPC_ID}|g; s|<subnet-id>|${SUBNET_ID}|g; s|<ebs-kms-key-id>|${KMS_KEY}|g;
        s|<key-pair-name>|${KEY_PAIR}|g; s|<owner-id>|${OWNER_ID}|g" "${WORK}"/policies/*.json "${WORK}"/roles/*.json

"${ROOT}/scripts/check-iam-literals.sh" --materialized "${WORK}" >/dev/null \
  || die 'the materialized tree failed the substitution gate — do not apply'
say 'substitution gate' 'clean'

echo "== validate every document before anything is written =="
for f in "${WORK}"/policies/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document "file://${f}" \
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`||findingType==`SECURITY_WARNING`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error/security finding(s)"
    say "$(basename "${f}")" 'clean'
done
for f in "${WORK}"/roles/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY --policy-document "file://${f}" \
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`&&issueCode!=`MISSING_RESOURCE`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error(s)"
    say "$(basename "${f}")" 'clean'
done

# ---- the declared object model ---------------------------------------------------------------
# Attachment is DECLARED here, not inferred from the file list. Inferring it — "attach every policy
# that is not the state policy to both deploy roles" — would attach `secure-wazuh-artifact-read` to
# the CI role and hand every deploy run the standing artifact authority the whole presigned-URL
# design exists to withhold. The reader is assumed per-fetch and attached to nothing else.
CI_ROLE="github_${OWNER}_${REPO}"
ADMIN_ROLE="github_${OWNER}_${REPO}-admin"
READER_ROLE="${REPO}-artifact-reader"

STATE_POLICY="github_${OWNER}_${REPO}"
DEPLOY_POLICIES=(
    "github_${OWNER}_${REPO}_deploy-ec2-launch"
    "github_${OWNER}_${REPO}_deploy-ec2-lifecycle"
    "github_${OWNER}_${REPO}_deploy-discovery-iam"
    "github_${OWNER}_${REPO}_deploy-sg-ssm-kms"
)
# policy source basename -> applied policy name
declare -A APPLIED_NAME=(
    ["${REPO}_deploy-ec2-launch"]="github_${OWNER}_${REPO}_deploy-ec2-launch"
    ["${REPO}_deploy-ec2-lifecycle"]="github_${OWNER}_${REPO}_deploy-ec2-lifecycle"
    ["${REPO}_deploy-discovery-iam"]="github_${OWNER}_${REPO}_deploy-discovery-iam"
    ["${REPO}_deploy-sg-ssm-kms"]="github_${OWNER}_${REPO}_deploy-sg-ssm-kms"
    ["github_${OWNER}_${REPO}"]="github_${OWNER}_${REPO}"
    ["${REPO}-artifact-read"]="${REPO}-artifact-read"
)
# applied policy name -> the roles that must carry it, and no others
declare -A EXPECTED_ROLES=(
    ["github_${OWNER}_${REPO}_deploy-ec2-launch"]="${CI_ROLE} ${ADMIN_ROLE}"
    ["github_${OWNER}_${REPO}_deploy-ec2-lifecycle"]="${CI_ROLE} ${ADMIN_ROLE}"
    ["github_${OWNER}_${REPO}_deploy-discovery-iam"]="${CI_ROLE} ${ADMIN_ROLE}"
    ["github_${OWNER}_${REPO}_deploy-sg-ssm-kms"]="${CI_ROLE} ${ADMIN_ROLE}"
    ["github_${OWNER}_${REPO}"]="${CI_ROLE}"
    ["${REPO}-artifact-read"]="${READER_ROLE}"
)
# `secure-wazuh-folder-admin.json` is deliberately absent from every map above: it is applied as an
# INLINE policy on the admin role, not as a managed one, so it has no ARN and no attachment.
INLINE_ONLY="${REPO}-folder-admin"

exists_policy() { aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/$1" --profile "${PROFILE}" >/dev/null 2>&1; }
exists_role()   { aws iam get-role --role-name "$1" --profile "${PROFILE}" >/dev/null 2>&1; }

# Compare two IAM documents SEMANTICALLY. IAM does not preserve the order of the arrays inside a
# document: `Principal.AWS` in particular comes back from get-role in an order unrelated to the one
# submitted, and it varies between calls. A naive `==` therefore reports drift on a document that is
# byte-for-byte correct in meaning — which is worse than no check at all, because an operator who
# learns to ignore this gate will ignore it on the day it is right. Order carries no meaning in a
# policy array (evaluation is set-based, and explicit Deny wins regardless of position), so sorting
# every scalar list before comparing loses nothing and removes the false positive.
#
# Written to a file rather than inlined so the policy and trust comparisons cannot drift apart.
cat > "${WORK}/docdiff.py" <<'PYEOF'
import json, sys, urllib.parse

def load(path):
    d = json.load(open(path))
    if isinstance(d, str):            # get-policy-version can return a URL-encoded string
        d = json.loads(urllib.parse.unquote(d))
    return d

def norm(x):
    if isinstance(x, dict):
        return {k: norm(v) for k, v in sorted(x.items())}
    if isinstance(x, list):
        out = [norm(i) for i in x]
        # sort scalars directly; sort dicts by a stable rendering so Statement order is ignored too
        return sorted(out, key=lambda i: json.dumps(i, sort_keys=True))
    return x

a, b = (norm(load(p).get('Statement')) for p in sys.argv[1:3])
if a == b:
    sys.exit(0)
if len(sys.argv) > 3 and sys.argv[3] == '--explain':
    sys.stderr.write('live: %s\nsrc : %s\n' % (json.dumps(a), json.dumps(b)))
sys.exit(1)
PYEOF

echo "== plan =="
for src in "${!APPLIED_NAME[@]}"; do
    p="${APPLIED_NAME[$src]}"
    say "policy ${p}" "$(exists_policy "${p}" && echo 'exists → new version' || echo 'CREATE')"
done
say "inline policy ${INLINE_ONLY}" 'on the -admin role; not managed'
for r in "${CI_ROLE}" "${ADMIN_ROLE}" "${EC2_ROLE}" "${READER_ROLE}"; do
    say "role ${r}" "$(exists_role "${r}" && echo 'exists → update trust' || echo 'CREATE')"
done
say "instance profile ${EC2_PROFILE}" "$(aws iam get-instance-profile --instance-profile-name "${EC2_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1 && echo exists || echo CREATE)"

# ---- drift mode --------------------------------------------------------------------------------
if [ "${DRIFT}" = 'true' ]; then
    drift=0
    echo "== document drift (source vs live) =="
    for src in "${!APPLIED_NAME[@]}"; do
        p="${APPLIED_NAME[$src]}"; arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
        if ! exists_policy "${p}"; then say "policy ${p}" 'ABSENT LIVE'; drift=1; continue; fi
        v="$(aws iam get-policy --policy-arn "${arn}" --profile "${PROFILE}" --query Policy.DefaultVersionId --output text)"
        aws iam get-policy-version --policy-arn "${arn}" --version-id "${v}" --profile "${PROFILE}" \
            --query PolicyVersion.Document --output json > "${WORK}/live.json"
        if python3 -S "${WORK}/docdiff.py" "${WORK}/live.json" "${WORK}/policies/${src}.json"; then
            say "policy ${p}" "in sync (${v})"
        else
            say "policy ${p}" "DRIFT — live ${v} differs from source"; drift=1
        fi
    done

    # The assertion that was missing. A policy can match its source perfectly and govern nothing.
    echo "== attachment drift (live attachment vs the declared role-to-policy map) =="
    for p in "${!EXPECTED_ROLES[@]}"; do
        exists_policy "${p}" || continue
        actual="$(aws iam list-entities-for-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/${p}" \
                  --profile "${PROFILE}" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null | tr '\t' '\n' | sort | tr '\n' ' ')"
        want="$(printf '%s\n' ${EXPECTED_ROLES[$p]} | sort | tr '\n' ' ')"
        if [ "${actual}" = "${want}" ]; then
            say "attachment ${p}" "correct (${want% })"
        elif [ -z "${actual// /}" ]; then
            say "attachment ${p}" "DETACHED — governs nothing; want ${want% }"; drift=1
        else
            say "attachment ${p}" "DRIFT — live '${actual% }' want '${want% }'"; drift=1
        fi
    done

    echo "== trust drift =="
    for pair in "${CI_ROLE}:github_${OWNER}_${REPO}.trust.json" \
                "${ADMIN_ROLE}:github_${OWNER}_${REPO}-admin.trust.json" \
                "${EC2_ROLE}:${EC2_ROLE}.trust.json" \
                "${READER_ROLE}:${READER_ROLE}.trust.json"; do
        role="${pair%%:*}"; tf="${pair#*:}"
        if ! exists_role "${role}"; then say "role ${role}" 'ABSENT LIVE'; drift=1; continue; fi
        aws iam get-role --role-name "${role}" --profile "${PROFILE}" --query Role.AssumeRolePolicyDocument --output json > "${WORK}/live.json"
        if python3 -S "${WORK}/docdiff.py" "${WORK}/live.json" "${WORK}/roles/${tf}"; then
            say "trust ${role}" 'in sync'
        else
            say "trust ${role}" 'DRIFT — live differs from source'; drift=1
        fi
    done

    [ "${drift}" -eq 0 ] || die 'live IAM has drifted from the tracked source. Re-run with --apply.'
    printf '\nbootstrap-iam: NO DRIFT — live IAM matches the tracked source, and every policy is\nattached to exactly the roles the map declares.\n'
    exit 0
fi

if ! ${APPLY}; then
    printf '\nbootstrap-iam: PLAN ONLY — nothing was written. Re-run with --apply.\n'
    exit 0
fi

echo "== apply =="
for src in "${!APPLIED_NAME[@]}"; do
    p="${APPLIED_NAME[$src]}"; arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
    if exists_policy "${p}"; then
        # keep at most 5 versions: prune the oldest non-default before adding
        if [ "$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" --query 'length(Versions)' --output text)" -ge 5 ]; then
            old="$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" \
                   --query 'sort_by(Versions[?!IsDefaultVersion],&CreateDate)[0].VersionId' --output text)"
            [ -n "${old}" ] && [ "${old}" != 'None' ] && \
              aws iam delete-policy-version --policy-arn "${arn}" --version-id "${old}" --profile "${PROFILE}" >/dev/null 2>&1
        fi
        v="$(aws iam create-policy-version --policy-arn "${arn}" --policy-document "file://${WORK}/policies/${src}.json" \
             --set-as-default --profile "${PROFILE}" --query 'PolicyVersion.VersionId' --output text)" \
            && say "policy ${p}" "new default version ${v}"
    else
        aws iam create-policy --policy-name "${p}" --policy-document "file://${WORK}/policies/${src}.json" \
            --description "${REPO} deploy boundary - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "policy ${p}" 'created'
    fi
done

apply_role() { # role-name trust-file
    local name="$1" trust="$2"
    if exists_role "${name}"; then
        aws iam update-assume-role-policy --role-name "${name}" --policy-document "file://${trust}" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'trust updated'
    else
        aws iam create-role --role-name "${name}" --assume-role-policy-document "file://${trust}" \
            --max-session-duration 3600 --description "${REPO} - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'created'
    fi
}
apply_role "${CI_ROLE}"     "${WORK}/roles/github_${OWNER}_${REPO}.trust.json"
apply_role "${ADMIN_ROLE}"  "${WORK}/roles/github_${OWNER}_${REPO}-admin.trust.json"
apply_role "${EC2_ROLE}"    "${WORK}/roles/${EC2_ROLE}.trust.json"
apply_role "${READER_ROLE}" "${WORK}/roles/${READER_ROLE}.trust.json"

attach() {
    aws iam attach-role-policy --role-name "$1" --policy-arn "$2" --profile "${PROFILE}" >/dev/null 2>&1 \
        || die "could not attach $(basename "$2") to $1 - the role may not exist"
}
for p in "${DEPLOY_POLICIES[@]}"; do
    attach "${CI_ROLE}"    "arn:aws:iam::${ACCOUNT}:policy/${p}"
    attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${p}"
done
# The state policy goes to the CI role only. The -admin role reaches Terraform state through the
# operator's own SSO permissions on the local deploy path.
attach "${CI_ROLE}"     "arn:aws:iam::${ACCOUNT}:policy/${STATE_POLICY}"
attach "${READER_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${REPO}-artifact-read"
attach "${EC2_ROLE}"    'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
say 'attachments' 'reconciled'

aws iam put-role-policy --role-name "${ADMIN_ROLE}" --policy-name "${INLINE_ONLY}" \
    --policy-document "file://${WORK}/policies/${INLINE_ONLY}.json" --profile "${PROFILE}" >/dev/null \
    && say "inline ${INLINE_ONLY}" 'applied to the -admin role'

if ! aws iam get-instance-profile --instance-profile-name "${EC2_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "${EC2_PROFILE}" --profile "${PROFILE}" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "${EC2_PROFILE}" --role-name "${EC2_ROLE}" --profile "${PROFILE}" >/dev/null
    say "instance profile ${EC2_PROFILE}" 'created'
fi

echo "== verify against the LIVE principal =="
sp() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}" \
       --action-names "$1" --resource-arns "$2" --context-entries "${@:3}" --profile "${PROFILE}" --region "${REGION}" \
       --query 'EvaluationResults[0].EvalDecision' --output text 2>&1 | tail -1; }
TAGK='ContextKeyName=ec2:ResourceTag/RepositoryId,ContextKeyType=string,ContextKeyValues'
REGK="ContextKeyName=aws:RequestedRegion,ContextKeyType=string,ContextKeyValues=${REGION}"
say 'DescribeImages in region (the 2026-08-03 regression)' "$(sp ec2:DescribeImages '*' "${REGK}")"
say 'terminate own tagged instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0a" "${REGK}" "${TAGK}=${REPO_ID}")"
say 'terminate a sibling repo instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0b" "${REGK}" "${TAGK}=1316209092")"
say 'iam:AttachRolePolicy (escalation probe)' "$(sp iam:AttachRolePolicy "arn:aws:iam::${ACCOUNT}:role/${EC2_ROLE}" "${REGK}")"
printf '\nbootstrap-iam: applied. A key pair (%s) is NOT created here — it carries private key\nmaterial whose custody is an operator decision.\n' "${KEY_PAIR}"
