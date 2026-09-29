#!/usr/bin/env python3
"""Validate the credential-free dependency declaration contract."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
ROOT = REPO_ROOT / "dependencies"
AWS = ROOT / "aws"
TOKENS = (
    "<account-id>",
    "<owner-id>",
    "<repository-id>",
    "<region>",
    "<vpc-id>",
    "<subnet-id>",
    "<ebs-kms-key-id>",
    "<key-pair-name>",
)
# These four occur only in the re-homed hardening, not in the proven live baseline.
ABSENT_TOKENS = (
    "<vpc-id>",
    "<subnet-id>",
    "<ebs-kms-key-id>",
    "<key-pair-name>",
)
FORBIDDEN = (
    "793496711039",
    "230745524",
    "1307854438",
    "us-east-1",
    "vpc-03c38504869c1c9bb",
    "subnet-0e1c8aae192deff26",
    "381209c1-5530-4c19-8f9d-5d75e401790b",
    "nwarila-ec2-key",
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")
# Alphanumeric boundaries avoid false positives on 12-digit substrings inside SHA-256 digests.
BARE_ACCOUNT = re.compile(r"(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])")
URI = re.compile(r"registry://[A-Za-z0-9._/-]+")
TOKEN = re.compile(r"<[a-z0-9-]+>")

POLICY_NAMES = (
    "nwarila-platform_secure-wazuh_admin_s3",
    "nwarila-platform_secure-wazuh_reaper_ebs",
    "nwarila-platform_secure-wazuh_reaper_ec2",
    "nwarila-platform_secure-wazuh_reaper_eni",
    "nwarila-platform_secure-wazuh_reaper_iam",
    "nwarila-platform_secure-wazuh_reaper_s3",
    "nwarila-platform_secure-wazuh_reaper_sg",
    "nwarila-platform_secure-wazuh_runner_ebs",
    "nwarila-platform_secure-wazuh_runner_ec2",
    "nwarila-platform_secure-wazuh_runner_eni",
    "nwarila-platform_secure-wazuh_runner_iam",
    "nwarila-platform_secure-wazuh_runner_kms",
    "nwarila-platform_secure-wazuh_runner_s3",
    "nwarila-platform_secure-wazuh_runner_sg",
    "nwarila-platform_secure-wazuh_runner_ssm",
    "secure-wazuh-artifact-read",
)
ROLE_ATTACH = {
    "nwarila-platform_secure-wazuh_admin": [
        "nwarila-platform_secure-wazuh_admin_s3",
        "nwarila-platform_secure-wazuh_runner_ebs",
        "nwarila-platform_secure-wazuh_runner_ec2",
        "nwarila-platform_secure-wazuh_runner_eni",
        "nwarila-platform_secure-wazuh_runner_iam",
        "nwarila-platform_secure-wazuh_runner_kms",
        "nwarila-platform_secure-wazuh_runner_s3",
        "nwarila-platform_secure-wazuh_runner_sg",
        "nwarila-platform_secure-wazuh_runner_ssm",
    ],
    "nwarila-platform_secure-wazuh_reaper": [
        "nwarila-platform_secure-wazuh_reaper_ebs",
        "nwarila-platform_secure-wazuh_reaper_ec2",
        "nwarila-platform_secure-wazuh_reaper_eni",
        "nwarila-platform_secure-wazuh_reaper_iam",
        "nwarila-platform_secure-wazuh_reaper_s3",
        "nwarila-platform_secure-wazuh_reaper_sg",
    ],
    "nwarila-platform_secure-wazuh_runner": [
        "nwarila-platform_secure-wazuh_runner_ebs",
        "nwarila-platform_secure-wazuh_runner_ec2",
        "nwarila-platform_secure-wazuh_runner_eni",
        "nwarila-platform_secure-wazuh_runner_iam",
        "nwarila-platform_secure-wazuh_runner_kms",
        "nwarila-platform_secure-wazuh_runner_s3",
        "nwarila-platform_secure-wazuh_runner_sg",
        "nwarila-platform_secure-wazuh_runner_ssm",
    ],
    "secure-wazuh-artifact-reader": ["secure-wazuh-artifact-read"],
}
MANAGED_ATTACH = {
    "nwarila-platform_secure-wazuh_admin": [],
    "nwarila-platform_secure-wazuh_reaper": [],
    "nwarila-platform_secure-wazuh_runner": [],
    "secure-wazuh-artifact-reader": [],
}
ROLE_METADATA = {
    "nwarila-platform_secure-wazuh_admin": {
        "session_seconds": 3600,
        "description": None,
        "path": "/",
        "managed_by": "consumer",
    },
    "nwarila-platform_secure-wazuh_reaper": {
        "session_seconds": 3600,
        "description": None,
        "path": "/",
        "managed_by": "consumer",
    },
    "nwarila-platform_secure-wazuh_runner": {
        "session_seconds": 7800,
        "description": None,
        "path": "/",
        "managed_by": "consumer",
    },
    "secure-wazuh-artifact-reader": {
        "session_seconds": 3600,
        "description": "Deploy-time artifact reads; assumed by the deploy roles only",
        "path": "/",
        "managed_by": "consumer",
    },
}
POLICY_DESCRIPTIONS = {name: None for name in POLICY_NAMES}
POLICY_DESCRIPTIONS["secure-wazuh-artifact-read"] = "Shared read-only Wazuh artifact access"
POLICY_VERSIONS = {name: "v1" for name in POLICY_NAMES}
POLICY_VERSIONS["secure-wazuh-artifact-read"] = "v5"

ARTIFACTS = (
    ("functions/wazuh/4.14.5/wazuh-offline.tar.gz", "1a60b8c407a56ed45a1e431256f6c49cba083a329874be7b532ec48a56069bea"),
    ("functions/wazuh/certs/internal-ca.pem", "52f0e2264fedcda543a320c3ddbed0783b5bf17146840df26a0e89265673cff7"),
    ("functions/wazuh/certs/indexer.p12", "3e1b602f995ac6b414cc4ac72fbb6709308dc7b7c42843d0ab34ecc483a345e6"),
    ("functions/wazuh/certs/admin.p12", "28f0d5941aebfe89fbc88c642fc079bfa9bf728e0f5d92aa66ee1e94a57e9c76"),
    ("functions/wazuh/certs/manager-api.p12", "c8ffa8e4fddc433bcad9abaa02bcc7b0e071e24c016dadbd00d87b3d2a4ccf45"),
    ("functions/wazuh/certs/dashboard.p12", "198590b78b46368a6963c619ae7e5d724151689e67c463305127a2a124fbbaa5"),
    ("applications/wazuh-agent/wazuh-agent-4.14.5-1.x86_64.rpm", "e320cdd225e56b311557de7b7ed9f176f10ef20315beac3de8846705495990da"),
    ("applications/wazuh-agent/wazuh-agent-4.14.5-1.msi", "bf35197fee30092d78aad648299e8fd3aba8a0f9bc7d5edebce483a0b2c8e38e"),
)
CERT_KEYS = {
    "functions/wazuh/certs/internal-ca.pem",
    "functions/wazuh/certs/indexer.p12",
    "functions/wazuh/certs/admin.p12",
    "functions/wazuh/certs/manager-api.p12",
    "functions/wazuh/certs/dashboard.p12",
}


class ContractError(Exception):
    """A dependency contract assertion failed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"JSON parse failed for {path.relative_to(REPO_ROOT)}: {error}") from error


def load_yaml(path: Path) -> Any:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ContractError(f"YAML parse failed for {path.relative_to(REPO_ROOT)}: {error}") from error


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label}: expected a mapping")
    return value


def require_keys(value: dict[str, Any], required: set[str], optional: set[str], label: str) -> None:
    actual = set(value)
    require(required <= actual, f"{label}: missing keys {sorted(required - actual)}")
    require(actual <= required | optional, f"{label}: unknown keys {sorted(actual - required - optional)}")


def require_string_list(value: Any, label: str) -> list[str]:
    require(isinstance(value, list), f"{label}: expected a list")
    require(all(isinstance(item, str) for item in value), f"{label}: every entry must be a string")
    require(value == sorted(set(value)), f"{label}: entries must be unique and lexical")
    return value


def manifest_bytes() -> bytes:
    rows = []
    paths = sorted(
        (path for path in ROOT.rglob("*") if path.is_file() and path.name != "MANIFEST.sha256"),
        key=lambda path: path.relative_to(ROOT).as_posix(),
    )
    for path in paths:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.append(f"{digest}  ./{path.relative_to(ROOT).as_posix()}\n")
    return "".join(rows).encode()


def check_integrity() -> None:
    require(ROOT.is_dir(), "dependencies/: directory is missing")
    symlinks = [path.relative_to(REPO_ROOT).as_posix() for path in ROOT.rglob("*") if path.is_symlink()]
    require(not symlinks, f"symlink refusal: {symlinks}")
    checksum = subprocess.run(
        ["sha256sum", "-c", "MANIFEST.sha256"],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    require(
        checksum.returncode == 0,
        "checksum verification failed for (cd dependencies && sha256sum -c MANIFEST.sha256): "
        + (checksum.stdout + checksum.stderr).strip(),
    )
    expected = manifest_bytes()
    actual = (ROOT / "MANIFEST.sha256").read_bytes()
    require(actual == expected, "MANIFEST.sha256 differs from deterministic regeneration")


def check_literals_and_tokens() -> None:
    for path in sorted(path for path in ROOT.rglob("*") if path.is_file()):
        text = path.read_text(encoding="utf-8")
        for literal in FORBIDDEN:
            require(literal not in text, f"forbidden concrete literal {literal!r} in {path.relative_to(REPO_ROOT)}")
        match = BARE_ACCOUNT.search(text)
        require(match is None, f"bare 12-digit run {match.group()!r} in {path.relative_to(REPO_ROOT)}" if match else "")
    iam_paths = [
        *sorted((AWS / "policies").glob("*.json")),
        *sorted((AWS / "roles").glob("*.trust.json")),
        *sorted((AWS / "profiles").glob("*.json")),
    ]
    corpus = "".join(path.read_text(encoding="utf-8") for path in iam_paths)
    observed = set(TOKEN.findall(corpus))
    unknown = observed - set(TOKENS)
    require(not unknown, f"IAM documents contain tokens outside the closed vocabulary: {sorted(unknown)}")
    expected = set(TOKENS) - set(ABSENT_TOKENS)
    require(
        observed == expected,
        f"IAM token set differs from the live-baseline presence record: "
        f"missing={sorted(expected - observed)} unexpectedly_present={sorted(observed - expected)}",
    )


def check_canonical_json() -> None:
    paths = [
        *sorted((AWS / "policies").glob("*.json")),
        *sorted((AWS / "roles").glob("*.trust.json")),
        *sorted((AWS / "profiles").glob("*.json")),
    ]
    for path in paths:
        document = load_json(path)
        expected = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
        require(path.read_bytes() == expected, f"canonical JSON serializer mismatch: {path.relative_to(REPO_ROOT)}")


def check_declarations() -> dict[str, dict[str, Any]]:
    require(not (AWS / "proposed").exists(), "aws/proposed/ must not exist in the desired-state tree")
    policy_json = {path.stem: path for path in (AWS / "policies").glob("*.json")}
    policy_yaml = sorted((AWS / "policies").glob("*.yml"))
    require(not policy_yaml, "policy YAML sidecars are forbidden; metadata belongs in aws/manifest.json")
    require(set(policy_json) == set(POLICY_NAMES), "desired policy JSON set differs from the closed expected set")

    trust_json = {path.name.removesuffix(".trust.json"): path for path in (AWS / "roles").glob("*.trust.json")}
    role_yaml = {path.stem: path for path in (AWS / "roles").glob("*.yml")}
    require(set(trust_json) == set(role_yaml) == set(ROLE_ATTACH), "role trust/YAML pairing is not one-to-one")
    roles = {}
    for name in sorted(role_yaml):
        path = role_yaml[name]
        sidecar = require_mapping(load_yaml(path), str(path.relative_to(REPO_ROOT)))
        required = {"schema", "name", "session_seconds", "trust", "attach", "managed_attach", "path", "description", "managed_by"}
        require_keys(sidecar, required, {"ratification"}, str(path.relative_to(REPO_ROOT)))
        require(sidecar["schema"] == "aws-role/v1", f"{name}: invalid role schema")
        require(sidecar["name"] == name, f"{name}: sidecar name must equal filename stem")
        require(sidecar["trust"] == f"{name}.trust.json", f"{name}: trust must name its paired JSON")
        require((AWS / "roles" / sidecar["trust"]).is_file(), f"{name}: trust document does not exist")
        for key, expected in ROLE_METADATA[name].items():
            require(sidecar[key] == expected, f"{name}: {key} differs from live metadata")
        attach = require_string_list(sidecar["attach"], f"{name}.attach")
        managed = require_string_list(sidecar["managed_attach"], f"{name}.managed_attach")
        require(attach == ROLE_ATTACH[name], f"{name}: customer-managed attachments differ from live")
        require(managed == MANAGED_ATTACH[name], f"{name}: AWS-managed attachments differ from live")
        require(set(attach) <= set(policy_json), f"{name}: an attached policy does not resolve")
        if "ratification" in sidecar:
            require(name == "secure-wazuh-artifact-reader", f"{name}: ratification is permitted only on the artifact-reader")
            require(sidecar["ratification"] == "registry://ratifications/artifact-reader", f"{name}: invalid ratification URI")
        require((name == "secure-wazuh-artifact-reader") == ("ratification" in sidecar), f"{name}: ratification presence is incorrect")
        roles[name] = sidecar
    attached_policy_names = {policy for attachments in ROLE_ATTACH.values() for policy in attachments}
    require(attached_policy_names == set(policy_json), "orphan policy file: desired policy attachment closure is incomplete")
    return roles


def check_profiles() -> dict[str, dict[str, Any]]:
    require(not (AWS / "profiles").exists(), "aws/profiles/ must not exist; shared profiles are external dependencies")
    return {}


def check_manifest(roles: dict[str, dict[str, Any]], profiles: dict[str, dict[str, Any]]) -> None:
    manifest = require_mapping(load_json(AWS / "manifest.json"), "aws/manifest.json")
    require(
        list(manifest) == ["exported", "roles", "policies", "divergence"],
        "manifest top-level key order/schema is invalid",
    )
    require(manifest["exported"] == "2026-09-28", "manifest exported date is not the verified export date")
    require(not profiles, "the closed export set contains no instance profiles")
    require(list(manifest["roles"]) == sorted(roles), "manifest roles must equal sidecars in lexical order")
    for name, sidecar in roles.items():
        attached = [{"name": policy, "version": POLICY_VERSIONS[policy]} for policy in sidecar["attach"]]
        attached.extend({"managed_by": "aws", "name": policy} for policy in sidecar["managed_attach"])
        attached.sort(key=lambda item: item["name"])
        require(manifest["roles"][name] == {"attached": attached, "inline": []}, f"manifest role mismatch: {name}")
    policy_files = {path.stem for path in (AWS / "policies").glob("*.json")}
    policies = require_mapping(manifest["policies"], "manifest.policies")
    require(set(policies) == policy_files, "manifest policies and policy JSON files are not bidirectionally equal")
    require(list(policies) == sorted(policies), "manifest policies must be in lexical order")
    for name, metadata in policies.items():
        expected = {
            "path": "/",
            "description": POLICY_DESCRIPTIONS[name],
            "tags": {},
            "managed_by": "consumer",
        }
        require(metadata == expected, f"manifest policy metadata differs from the closed expected table: {name}")

    divergence = require_mapping(manifest["divergence"], "manifest.divergence")
    require(set(divergence) == {"note", "not_yet_applied"}, "manifest.divergence exact schema violation")
    require(isinstance(divergence["note"], str) and divergence["note"], "manifest.divergence.note must be non-empty")
    not_yet_applied = require_string_list(
        divergence["not_yet_applied"], "manifest.divergence.not_yet_applied"
    )
    require(
        set(not_yet_applied) <= policy_files,
        "manifest.divergence.not_yet_applied names a policy without a real policy JSON",
    )


def check_artifacts() -> None:
    document = require_mapping(load_yaml(AWS / "artifacts.yml"), "aws/artifacts.yml")
    require(set(document) == {"schema", "artifacts"}, "aws/artifacts.yml: unknown or missing top-level keys")
    require(document["schema"] == "aws-artifacts/v1", "aws/artifacts.yml: invalid schema")
    items = document["artifacts"]
    require(isinstance(items, list), "aws/artifacts.yml: artifacts must be a list")
    require([item.get("key") for item in items] == [key for key, _ in ARTIFACTS], "artifact object set/order differs from the closed list")
    expected_digests = dict(ARTIFACTS)
    for item in items:
        item = require_mapping(item, "aws/artifacts.yml entry")
        required = {"bucket", "key", "sha256", "access"}
        require_keys(item, required, {"path_status", "status"}, f"artifact {item.get('key')}")
        key = item["key"]
        require(HEX64.fullmatch(str(item["sha256"])) is not None, f"artifact {key}: sha256 must be lowercase 64-hex")
        require(item["sha256"] == expected_digests[key], f"artifact {key}: digest differs from the closed pin")
        require(item["bucket"] == "registry://aws/s3/ansible", f"artifact {key}: bucket is incorrect")
        require(item["access"] == "presigned-via-artifact-reader", f"artifact {key}: access is incorrect")
        require(item.get("path_status") == "disconnected-pending-m1", f"artifact {key}: path_status is incorrect")
        require((item.get("status") == "proposed-m1") == (key in CERT_KEYS), f"artifact {key}: status is incorrect")


def check_registry_closure() -> None:
    resolver = require_mapping(load_yaml(ROOT / "registry-values.yml"), "registry-values.yml")
    expected = {
        "registry://aws/s3/ansible": {
            "value": "<account-id>-ansible",
            "evidence": "_handoff/refactor-2026-09-28/iam-research/live/policies/nwarila-platform_secure-wazuh_runner_s3.document.json",
        },
        "registry://ratifications/artifact-reader": {
            "value": "docs/reference/aws-iam/README.md#the-artifact-reader-design",
            "evidence": "docs/reference/aws-iam/README.md:143: ## The artifact-reader design",
        },
    }
    require(resolver == expected, "registry-values.yml must contain exactly the two evidenced resolver entries")
    used = set()
    for path in sorted(path for path in ROOT.rglob("*") if path.is_file()):
        if path.name in {"registry-values.yml", "README.md"}:
            continue
        used.update(URI.findall(path.read_text(encoding="utf-8")))
    require(used == set(resolver), f"registry URI closure mismatch: used_only={sorted(used - set(resolver))} resolver_only={sorted(set(resolver) - used)}")


def main() -> int:
    try:
        check_integrity()
        check_literals_and_tokens()
        check_canonical_json()
        roles = check_declarations()
        profiles = check_profiles()
        check_manifest(roles, profiles)
        check_artifacts()
        check_registry_closure()
    except ContractError as error:
        print(f"dependency check failed: {error}", file=sys.stderr)
        return 1
    print("dependency check passed: desired declarations, metadata, closure, literals, and integrity are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
