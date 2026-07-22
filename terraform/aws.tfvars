# AWS ephemeral PoC inputs for secure-wazuh (consumed by aws-terraform-framework).
#
# This target is the throwaway proof-of-concept half of the repo: every commit to main runs
# deploy -> smoke-test -> DESTROY, so nothing here is meant to persist. The permanent live
# instance is the Proxmox target (see proxmox.tfvars).
#
# NO secrets live in this file. AWS credentials reach the runner through GitHub OIDC
# (assume-role) and are never committed. Values marked REPLACE_ME are account/VPC-specific
# identifiers an operator must fill before the first apply.
#
# Note on operator access: this framework references pre-provisioned security groups by ID;
# it does NOT build a security group from a CIDR. The operator-CIDR restriction is therefore
# expressed on the security group referenced under network_interfaces below (see the REQUIRED
# comment there), which is the required-to-fill gate for reaching this box.

environment = "poc"

# Readiness gate: path (on the Terraform runner) to the OpenSSH private key matching
# all_systems[*].key_name. Leave {} for plan-only / CI-lint; a real deploy-test-destroy apply
# must supply the path so the gate can SSH in before Ansible configures the stack.
readiness_private_key_paths = {
  "secure-wazuh-poc-key" = "/secure/path/REPLACE_ME-secure-wazuh-poc-key.pem"
}

# STIG-hardened RHEL/Rocky 8 images commonly mount /tmp, /var/tmp, and /dev/shm noexec, which
# breaks the gate's default remote-exec upload dir. Point it at the login user's home instead.
readiness_linux_script_dir = "/home/rocky"

all_systems = [
  {
    # Single all-in-one box: indexer/OpenSearch + manager + Filebeat + dashboard on one host.
    region            = "us_east_1"
    hostname          = "secure-wazuh-poc"
    availability_zone = "us-east-1a"

    # REQUIRED - account/VPC specific. Fill before apply.
    subnet_id            = "subnet-REPLACE_ME"    # private subnet in us-east-1a
    key_name             = "secure-wazuh-poc-key" # must match a readiness_private_key_paths key
    iam_instance_profile = "REPLACE_ME-wazuh-poc-profile"
    aws_kms_alias        = "REPLACE_ME-wazuh-poc-ebs" # EBS CMK alias WITHOUT the "alias/" prefix

    # Self-built, STIG/FIPS-baselined Rocky 8 AMI family (resolves to the glob
    # rocky_linux_8_x64_v*). Default login user on the image is "rocky".
    ami            = "rocky_linux_8_x64"
    readiness_user = "rocky"

    # 4 vCPU / 16 GB - clears the AIO floor (>=4 vCPU / 8 GB) with headroom for the OpenSearch
    # JVM heap. Mirrors the permanent Proxmox box (4 cores / 8 GB) with slack for indexing bursts.
    instance_type = "m6i.xlarge"

    # OS root. Every EBS volume is encrypted by the framework with the CMK from aws_kms_alias.
    root_block_device = {
      volume_type = "gp3"
      volume_size = "50"
    }

    # Dedicated data volume for /mnt/data (Wazuh indexer + alert storage). Ephemeral sizing;
    # the permanent Proxmox box carries 256 GB. The framework assigns the device name
    # (first extra volume -> /dev/sdd, surfaced as /dev/nvme1n1 on Nitro); the Ansible layer
    # resolves that device and mounts it at /mnt/data.
    ebs_block_devices = [
      {
        volume_type = "gp3"
        volume_size = "100"
      }
    ]

    tags = {
      Function = "wazuh-aio"
      Backup   = false # ephemeral PoC - destroyed every cycle, nothing to back up
    }

    network_interfaces = [
      {
        private_ip = "10.0.10.10" # REPLACE_ME if it collides in your subnet

        # REQUIRED - operator access gate. This security group is where the operator CIDR is
        # enforced: it MUST restrict inbound to the operator's own public CIDR only (TCP 443
        # dashboard, TCP 22 SSH/readiness) and MUST NOT allow 0.0.0.0/0. The framework does not
        # synthesize a security group from a CIDR - reference a pre-provisioned SG ID here.
        security_groups = ["sg-REPLACE_ME"]
      }
    ]
  }
]

# An ephemeral single-box PoC needs no managed database and no load balancer. Keeping these
# lists empty is how this framework expresses "no RDS" and "no ALB/NLB".
all_databases      = []
all_load_balancers = []
