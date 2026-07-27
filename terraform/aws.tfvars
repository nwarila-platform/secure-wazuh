# AWS ephemeral PoC inputs for secure-wazuh (consumed by aws-terraform-framework).
#
# This target is the throwaway proof-of-concept half of the repo, driven two ways:
#   - deploy.yml (push to main touching ansible/**, terraform/**, or .github/.framework-pin; plus
#     workflow_dispatch): deploy -> smoke-test -> DESTROY, nothing persists (~$1 per run).
#   - e2e-full.yml (MR opened/reopened/draft-to-ready or `rerun-poc` labeled, with changes touching
#     ansible/**, terraform/**, .github/.framework-pin, or the workflow itself; plus
#     workflow_dispatch): deploy -> prove (phase 1) -> OS-swap the AIO
#     (terraform apply -var refresh_serial=1) -> prove again, cumulatively (phase 2) -> DESTROY
#     (~$1 per run).
# The permanent live instance is the Proxmox target (see proxmox.tfvars) — unrelated to this file.
#
# NO secrets, and NO AWS account id, live in this file (the account-id ban is absolute — see
# ADR-0004). AWS credentials reach the runner through GitHub OIDC (assume-role) and are never
# committed. Every value below is real, committed bootstrap data — this file carries no
# REPLACE_ME placeholders; it is consumed directly by both workflows above.
#
# Security groups are interface-scoped in this PoC: every network_interfaces entry declares flat
# ingress and egress rules. The framework creates "<hostname>-eni-<index>-sg" from that interface's
# description and tags, then attaches it only to that interface. security_groups is reserved for
# pre-created EC2 group IDs; this PoC uses none, so every list is [].

environment = "dev"

# Readiness gate: path (on the Terraform runner) to the OpenSSH private key matching
# all_systems[*].key_name. All 3 systems below keep readiness_gate = false: their interface groups
# expose no SSH ingress (the agents are zero-inbound), so the gate's direct-SSH precheck cannot
# reach them. This path is not exercised by either workflow today; it is still supplied as real
# bootstrap data (the runner-local convention ansible/inventory/aws/group_vars/all.yml already
# assumes for its own ansible_ssh_private_key_file) rather than left as a placeholder.
readiness_private_key_paths = {
  "secure-wazuh-poc-key" = "/root/.ssh/secure-wazuh-poc-key.pem"
}

# STIG-hardened RHEL/Rocky 8 images commonly mount /tmp, /var/tmp, and /dev/shm noexec, which
# breaks the gate's default remote-exec upload dir. Point it at the login user's home instead.
readiness_linux_script_dir = "/home/ec2-user"

all_systems = [
  {
    # Single all-in-one box: indexer/OpenSearch + manager + Filebeat + dashboard on one host.
    region            = "us_east_1"
    hostname          = "secure-wazuh-poc"
    availability_zone = "us-east-1a"

    # public subnet secure-wazuh-public-use1a (IGW-routed, auto-assign public IP — see
    # docs/reference/aws-iam/README.md "PoC networking")
    subnet_id            = "subnet-0e1c8aae192deff26"
    key_name             = "secure-wazuh-poc-key" # must match a readiness_private_key_paths key
    iam_instance_profile = "secure-wazuh-poc-profile"
    # aws/ebs = the AWS-managed default EBS key (satisfies encrypted-at-rest for STIG/FIPS). A
    # customer-managed CMK is an optional hardening upgrade (key control/rotation/audit), not required.
    aws_kms_alias = "aws/ebs" # AWS-managed default EBS key alias (no "alias/" prefix)

    # CIS/DISA RHEL 8 Benchmark STIG marketplace AMI (Red Hat, DISA-STIG-hardened), us-east-1.
    # Default login user on the image is "ec2-user". (Rocky 8 is the free on-prem/Proxmox image;
    # AWS deploys the RHEL 8 DISA STIG marketplace image.)
    ami            = "ami-0ca8a2e788e4c5869"
    readiness_user = "ec2-user"
    readiness_gate = false # SSM-only reachability; see the file header

    # SSM-over-SSH only; IMDSv2 already required module-wide (deploy policy + ADR repo/0001).
    imds_hop_limit = 1
    set_state      = null

    # 4 vCPU / 16 GB - clears the AIO floor (>=4 vCPU / 8 GB) with headroom for the OpenSearch
    # JVM heap. Mirrors the permanent Proxmox box (4 cores / 8 GB) with slack for indexing bursts.
    instance_type = "m6i.xlarge"

    # e2e-full.yml's OS-swap lever: `terraform apply -var refresh_serial=1` force-replaces every
    # refresh=true instance — a fresh root volume from `ami` above, new instance-id, but its data
    # volume (ebs_block_devices below) is UNAFFECTED and gets re-attached to the new instance
    # (Terraform replaces the aws_instance resource, not the separate aws_ebs_volume). This is
    # the "replace-OS-only" proof: the AIO's indexer data and the FIM ledger written by
    # deploy-aws-poc.yml Stage 4 survive even though the OS underneath does not. The two
    # agents below stay refresh = false so the swap never touches them — only the AIO OS is tested.
    refresh = true

    tags = {
      Function = "wazuh-aio"
      Backup   = false # ephemeral PoC - destroyed every cycle, nothing to back up
    }

    # OS root. Every EBS volume is encrypted by the framework with the CMK from aws_kms_alias.
    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # Dedicated data volume for /mnt/data (Wazuh indexer + alert storage, and the ledger written
    # by deploy-aws-poc.yml Stage 4). Ephemeral sizing; the permanent Proxmox box carries 256 GB. The
    # framework assigns this volume's device name positionally (first extra volume -> /dev/sdd)
    # — but consumers must NEVER use positional names (Nitro can re-enumerate NVMe devices across
    # reboots, and this volume is explicitly re-attached across an OS-swap replacement too).
    # Identification instead goes tags.Function -> volume-id -> /dev/disk/by-id NVMe-serial:
    # linux_disk_manager's AWS resolver (ansible-framework, tasks/resolve_aws.yml) reads the
    # Function tag below at apply time and derives the by-id path itself; no /dev/nvmeXnY or
    # /dev/sdX name is ever consulted.
    ebs_block_devices = [
      {
        volume_type  = "gp3"
        volume_size  = "100"
        iops         = null
        throughput   = null
        snapshot_id  = null
        skip_destroy = false # ephemeral PoC - destroy-always must be able to remove this volume
        tags = {
          Function = "wazuh-data"
        }
      }
    ]

    network_interfaces = [
      {
        private_ip = "10.1.10.20"

        # The interface-owned group declared below is attached automatically. No pre-created groups
        # are used.
        security_groups = []
        description     = "Wazuh AIO (manager+dashboard+indexer) system-specific inbound firewall."
        interface_type  = null
        tags = {
          Environment = "dev"
          System      = "wazuh"
          Role        = "wazuh-aio"
        }

        ingress = [
          {
            description                  = "Wazuh manager: agent events (1514) + enrollment (1515) from the deploy subnet"
            ip_protocol                  = "tcp"
            from_port                    = 1514
            to_port                      = 1515
            cidr_ipv4                    = "10.1.10.0/24"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]

        # Outbound-all preserves S3 artifact downloads, SSM registration, DNS, and package installs.
        egress = [
          {
            description                  = "All outbound"
            ip_protocol                  = "-1"
            from_port                    = null
            to_port                      = null
            cidr_ipv4                    = "0.0.0.0/0"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
      }
    ]

    # The subnet auto-assigns public IPs; this framework's own EIP path is not used here. The
    # interface group has no Internet-sourced ingress, so SSM remains the only administrative path.
    associate_public_ip = false
  },
  {
    # Linux endpoint agent: enrolls against the AIO above; Stage 3a of deploy-aws-poc.yml proves
    # its agent-sourced FIM path distinctly from the manager's own local agent 000.
    region            = "us_east_1"
    hostname          = "secure-wazuh-poc-agent-linux"
    availability_zone = "us-east-1a"

    subnet_id            = "subnet-0e1c8aae192deff26"
    key_name             = "secure-wazuh-poc-key"
    iam_instance_profile = "secure-wazuh-poc-profile"
    aws_kms_alias        = "aws/ebs"
    ami                  = "ami-0ca8a2e788e4c5869" # same RHEL 8 STIG AMI as the AIO
    readiness_user       = "ec2-user"
    readiness_gate       = false
    imds_hop_limit       = 1
    set_state            = null
    instance_type        = "t3.medium"
    refresh              = false # agents stay untouched by the AIO's OS-swap lever

    tags = {
      Function = "wazuh-agent"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    ebs_block_devices = [] # no dedicated data volume — agents are stateless

    network_interfaces = [
      {
        private_ip = "10.1.10.21"

        # This interface's group intentionally has zero inbound rules. No pre-created groups are used.
        security_groups = []
        description     = "Linux Wazuh agent system-specific zero-inbound firewall."
        interface_type  = null
        tags = {
          Environment = "dev"
          System      = "wazuh"
          Role        = "wazuh-agent"
        }

        ingress = []

        # Outbound-all preserves S3 artifact downloads, SSM registration, DNS, and package installs.
        egress = [
          {
            description                  = "All outbound"
            ip_protocol                  = "-1"
            from_port                    = null
            to_port                      = null
            cidr_ipv4                    = "0.0.0.0/0"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
      }
    ]

    associate_public_ip = false
  },
  {
    # Windows endpoint agent: same normal role entry as the Linux agent above, dispatched to the
    # native win_* enrollment path by the shared loader.
    region            = "us_east_1"
    hostname          = "secure-wazuh-poc-agent-win"
    availability_zone = "us-east-1a"

    subnet_id            = "subnet-0e1c8aae192deff26"
    key_name             = "secure-wazuh-poc-key" # same EC2 launch key pair as the Linux systems
    iam_instance_profile = "secure-wazuh-poc-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows Server 2025 STIG-Core marketplace AMI (DISA-STIG-hardened), us-east-1.
    ami            = "ami-003a141a4ebc8189d"
    readiness_user = "Administrator"
    readiness_gate = false
    imds_hop_limit = 1
    set_state      = null
    instance_type  = "t3.medium"
    refresh        = false # agents stay untouched by the AIO's OS-swap lever

    tags = {
      Function = "wazuh-agent" # SAME Function as the Linux agent; aws_ec2.yml's group split is
      # by the AWS-native `platform` field (Windows vs absent), not a second Function value.
      Backup = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    ebs_block_devices = []

    network_interfaces = [
      {
        private_ip = "10.1.10.22"

        # This interface's group intentionally has zero inbound rules. No pre-created groups are used.
        security_groups = []
        description     = "Windows Wazuh agent system-specific zero-inbound firewall."
        interface_type  = null
        tags = {
          Environment = "dev"
          System      = "wazuh"
          Role        = "wazuh-agent"
        }

        ingress = []

        # Outbound-all preserves S3 artifact downloads, SSM registration, DNS, and package installs.
        egress = [
          {
            description                  = "All outbound"
            ip_protocol                  = "-1"
            from_port                    = null
            to_port                      = null
            cidr_ipv4                    = "0.0.0.0/0"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
      }
    ]

    associate_public_ip = false
  }
]

# An ephemeral single-box-plus-agents PoC needs no managed database and no load balancer. Keeping
# these lists empty is how this framework expresses "no RDS" and "no ALB/NLB".
all_databases      = []
all_load_balancers = []
