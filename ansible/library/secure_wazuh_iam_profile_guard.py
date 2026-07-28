#!/usr/bin/python

from __future__ import annotations

DOCUMENTATION = r"""
---
module: secure_wazuh_iam_profile_guard
short_description: Reject legacy artifact authority on the target instance profile
description:
  - Reads one exact IAM instance profile on the Ansible controller.
  - Fails closed unless the profile contains the expected role, its managed-policy ARN is exact,
    it has no inline policies, and it does not carry the forbidden legacy artifact-policy name.
options:
  instance_profile_name:
    description: Exact target instance-profile name.
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
    instance_profile_name: secure-wazuh-poc-profile
    expected_role_name: secure-wazuh-poc-role
    expected_managed_policy_arn: arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    forbidden_policy_name: secure-wazuh-artifact-read
"""

RETURN = r"""
legacy_policy_absent:
  description: Whether the expected role is free of the forbidden policy name.
  returned: success
  type: bool
"""

from ansible.module_utils.basic import AnsibleModule

try:
    import boto3
except ImportError:
    boto3 = None


def _iam_client(module):
    try:
        return boto3.client("iam")
    except Exception:
        module.fail_json(msg="Unable to initialize the IAM client.")


def _profile_role_name(module, client):
    try:
        profile = client.get_instance_profile(
            InstanceProfileName=module.params["instance_profile_name"],
        )["InstanceProfile"]
    except Exception:
        module.fail_json(msg="Unable to inspect the target instance profile.")

    roles = profile.get("Roles", [])
    expected_role_name = module.params["expected_role_name"]
    if len(roles) != 1 or roles[0].get("RoleName") != expected_role_name:
        module.fail_json(msg="The target instance profile does not contain exactly the expected role.")
    return expected_role_name


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


def main():
    module = AnsibleModule(
        argument_spec={
            "instance_profile_name": {"type": "str", "required": True},
            "expected_role_name": {"type": "str", "required": True},
            "expected_managed_policy_arn": {"type": "str", "required": True},
            "forbidden_policy_name": {"type": "str", "required": True},
        },
        supports_check_mode=True,
    )

    if boto3 is None:
        module.fail_json(msg="boto3 is required on the Ansible controller.")

    client = _iam_client(module)
    role_name = _profile_role_name(module, client)
    attached_policies, inline_names = _role_policies(module, client, role_name)
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

    module.exit_json(changed=False, legacy_policy_absent=True)


if __name__ == "__main__":
    main()
