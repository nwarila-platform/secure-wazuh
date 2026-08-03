#!/usr/bin/python

from __future__ import annotations

DOCUMENTATION = r"""
---
module: secure_wazuh_iam_profile_guard
short_description: Reject artifact authority on the run's EC2 instance profile
description:
  - Reads one exact IAM instance profile and the run-scoped EC2 instances on the Ansible controller.
  - Fails closed unless every supplied instance exists and uses that exact profile.
  - Fails closed unless the profile contains the expected role, its managed-policy ARN is exact,
    it has no inline policies, and it does not carry the forbidden legacy artifact-policy name.
  - Reads the artifact bucket policy and rejects a resource-based Allow for the instance role.
options:
  instance_profile_name:
    description: Exact target instance-profile name.
    type: str
    required: true
  run_instance_ids:
    description: EC2 instance IDs from the already validated run-scoped Ansible inventory.
    type: list
    elements: str
    required: true
  region:
    description: Region containing every supplied run-scoped EC2 instance.
    type: str
    required: true
  artifact_bucket:
    description: Exact artifact bucket whose resource policy must not grant the instance role.
    type: str
    required: true
  expected_role_name:
    description: Exact role that must be contained by the instance profile.
    type: str
    required: true
  expected_managed_policy_arn:
    description: Exact ARN of the only managed policy that may remain attached to the role.
    type: str
    required: true
  forbidden_policy_name:
    description: Managed or inline policy name that must not be attached to the role.
    type: str
    required: true
author:
  - secure-wazuh maintainers
"""

EXAMPLES = r"""
- name: Reject the legacy artifact policy on the target profile
  delegate_to: localhost
  secure_wazuh_iam_profile_guard:
    instance_profile_name: nwarila-ec2-profile
    run_instance_ids: "{{ run_scoped_instance_ids }}"
    region: us-east-1
    artifact_bucket: your-org-artifact-bucket
    expected_role_name: nwarila-ec2-role
    expected_managed_policy_arn: arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    forbidden_policy_name: secure-wazuh-artifact-read
"""

RETURN = r"""
legacy_policy_absent:
  description: Whether the expected role is free of the forbidden policy name.
  returned: success
  type: bool
run_instances_bound:
  description: Whether every supplied run instance uses the exact inspected profile.
  returned: success
  type: bool
bucket_policy_grant_absent:
  description: Whether the artifact bucket policy has no Allow for the instance role.
  returned: success
  type: bool
"""

import json

from ansible.module_utils.basic import AnsibleModule

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    boto3 = None
    ClientError = None


def _client(module, service):
    try:
        return boto3.client(service, region_name=module.params["region"])
    except Exception:
        module.fail_json(msg="Unable to initialize an AWS guard client.")


def _instance_profile(module, client):
    try:
        return client.get_instance_profile(
            InstanceProfileName=module.params["instance_profile_name"],
        )["InstanceProfile"]
    except Exception:
        module.fail_json(msg="Unable to inspect the target instance profile.")


def _profile_role(module, profile):
    roles = profile.get("Roles", [])
    expected_role_name = module.params["expected_role_name"]
    if (
        len(roles) != 1
        or roles[0].get("RoleName") != expected_role_name
        or not roles[0].get("Arn")
    ):
        module.fail_json(msg="The target instance profile does not contain exactly the expected role.")
    return roles[0]


def _assert_run_instances_use_profile(module, client, profile):
    instance_ids = module.params["run_instance_ids"]
    if not instance_ids or len(instance_ids) != len(set(instance_ids)):
        module.fail_json(msg="The run-scoped instance ID set must be non-empty and unique.")

    try:
        response = client.describe_instances(InstanceIds=instance_ids)
    except Exception:
        module.fail_json(msg="Unable to inspect the run-scoped EC2 instances.")

    instances = [
        instance
        for reservation in response.get("Reservations", [])
        for instance in reservation.get("Instances", [])
    ]
    observed_ids = [instance.get("InstanceId") for instance in instances]
    if (
        len(observed_ids) != len(instance_ids)
        or len(observed_ids) != len(set(observed_ids))
        or set(observed_ids) != set(instance_ids)
    ):
        module.fail_json(msg="EC2 did not return exactly the run-scoped instance ID set.")

    profile_bindings = []
    for instance in instances:
        binding = instance.get("IamInstanceProfile")
        if (
            not isinstance(binding, dict)
            or not binding.get("Arn")
            or not binding.get("Id")
        ):
            module.fail_json(msg="A run-scoped EC2 instance has no complete IAM instance profile.")
        profile_bindings.append((binding["Arn"], binding["Id"]))

    distinct_bindings = set(profile_bindings)
    if len(distinct_bindings) != 1:
        module.fail_json(msg="The run-scoped EC2 instances use more than one IAM instance profile.")

    expected_binding = (profile.get("Arn"), profile.get("InstanceProfileId"))
    if not all(expected_binding) or distinct_bindings != {expected_binding}:
        module.fail_json(msg="The run-scoped EC2 instances do not use the inspected instance profile.")


def _role_policies(module, client, role_name):
    try:
        attached = client.get_paginator("list_attached_role_policies").paginate(
            RoleName=role_name,
        )
        inline = client.get_paginator("list_role_policies").paginate(
            RoleName=role_name,
        )
        attached_policies = [
            policy
            for page in attached
            for policy in page.get("AttachedPolicies", [])
        ]
        inline_names = {
            policy_name
            for page in inline
            for policy_name in page.get("PolicyNames", [])
        }
    except Exception:
        module.fail_json(msg="Unable to inspect the target instance-role policies.")
    return attached_policies, inline_names


def _principal_includes_role(principal, role_arn):
    if isinstance(principal, str):
        return principal in {"*", role_arn}
    if isinstance(principal, list):
        return any(_principal_includes_role(value, role_arn) for value in principal)
    if isinstance(principal, dict):
        return _principal_includes_role(principal.get("AWS"), role_arn)
    return False


def _bucket_policy_grants_role(module, client, role_arn):
    try:
        policy_text = client.get_bucket_policy(
            Bucket=module.params["artifact_bucket"],
        ).get("Policy")
    except Exception as exc:
        if (
            ClientError is not None
            and isinstance(exc, ClientError)
            and exc.response.get("Error", {}).get("Code") == "NoSuchBucketPolicy"
        ):
            return False
        module.fail_json(msg="Unable to inspect the artifact bucket policy.")

    if not isinstance(policy_text, str) or not policy_text.strip():
        module.fail_json(msg="The artifact bucket policy response is incomplete.")
    try:
        policy = json.loads(policy_text)
    except (TypeError, ValueError):
        module.fail_json(msg="The artifact bucket policy is not valid JSON.")
    if not isinstance(policy, dict):
        module.fail_json(msg="The artifact bucket policy is not a JSON object.")

    statements = policy.get("Statement")
    if isinstance(statements, dict):
        statements = [statements]
    if not isinstance(statements, list):
        module.fail_json(msg="The artifact bucket policy has no valid statement list.")

    for statement in statements:
        if not isinstance(statement, dict):
            module.fail_json(msg="The artifact bucket policy contains an invalid statement.")
        if statement.get("Effect") != "Allow":
            continue
        if _principal_includes_role(statement.get("Principal"), role_arn):
            return True
        if (
            "NotPrincipal" in statement
            and not _principal_includes_role(statement.get("NotPrincipal"), role_arn)
        ):
            return True
    return False


def main():
    module = AnsibleModule(
        argument_spec={
            "instance_profile_name": {"type": "str", "required": True},
            "run_instance_ids": {
                "type": "list",
                "elements": "str",
                "required": True,
            },
            "region": {"type": "str", "required": True},
            "artifact_bucket": {"type": "str", "required": True, "no_log": True},
            "expected_role_name": {"type": "str", "required": True},
            "expected_managed_policy_arn": {"type": "str", "required": True},
            "forbidden_policy_name": {"type": "str", "required": True},
        },
        supports_check_mode=True,
    )

    if boto3 is None:
        module.fail_json(msg="boto3 is required on the Ansible controller.")

    iam_client = _client(module, "iam")
    profile = _instance_profile(module, iam_client)
    role = _profile_role(module, profile)
    _assert_run_instances_use_profile(module, _client(module, "ec2"), profile)
    attached_policies, inline_names = _role_policies(
        module,
        iam_client,
        role["RoleName"],
    )
    attached_names = {
        policy.get("PolicyName")
        for policy in attached_policies
    }
    if module.params["forbidden_policy_name"] in attached_names | inline_names:
        module.fail_json(msg="The target instance role still carries the legacy artifact policy.")
    if (
        len(attached_policies) != 1
        or attached_policies[0].get("PolicyArn")
        != module.params["expected_managed_policy_arn"]
        or inline_names
    ):
        module.fail_json(msg="The target instance role does not match the exact SSM-only policy set.")

    if _bucket_policy_grants_role(
        module,
        _client(module, "s3"),
        role["Arn"],
    ):
        module.fail_json(msg="The artifact bucket policy grants the target instance role.")

    module.exit_json(
        changed=False,
        legacy_policy_absent=True,
        run_instances_bound=True,
        bucket_policy_grant_absent=True,
    )


if __name__ == "__main__":
    main()
