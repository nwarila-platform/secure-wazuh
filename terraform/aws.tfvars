# 
environment = "dev"



all_systems = [
  {

    ami                 = "ami-0ca8a2e788e4c5869"
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Linux AIO; SSH over an SSM session.
    connection_type      = "ssh-ssm"
    hostname             = "secure-wazuh-poc"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "m6i.xlarge"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "ec2-user"
    refresh                    = true
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-aio"
      # The AIO is administered over the tunnel. Stated explicitly rather than relying on the
      # inventory's untagged default, so this and connection_type = "ssh-ssm" above are visibly
      # the same decision. MUST AGREE WITH IT — see any agent block below for why disagreement
      # fails as a timeout rather than an error.
      Connection = "ssm-ssh"
      Backup     = false #
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # The CIS RHEL 8 AMI ships TWO devices: /dev/sda1 (root, handled by root_block_device, which
    # the framework forces encrypted) and a 40 GiB /dev/sdf the image defines and Terraform would
    # otherwise never see. Verified against describe-images: gp3, 40 GiB, 3000 iops, 125 MiB/s,
    # Encrypted=false. Restating it here re-renders the mapping with encrypted = true, which is the
    # only declarative way to encrypt a device the AMI ships unencrypted.
    #
    # This replaces reliance on the account-level enable-ebs-encryption-by-default setting: that
    # works, but it is ambient state no reviewer of this repository can see, and it silently stops
    # protecting the deployment if anyone reverts it.
    #
    # No collision with ebs_block_devices: the framework assigns those suffixes starting at 'd'
    # (/dev/sdd, /dev/sde, ...), so only a THIRD data volume would reach /dev/sdf.
    ami_block_device_overrides = [
      {
        delete_on_termination = true
        device_name           = "/dev/sdf"
        iops                  = "3000"
        throughput            = "125"
        volume_size           = "40"
        volume_type           = "gp3"
      }
    ]

    ebs_block_devices = [
      {
        # Stable identity so a future reorder cannot re-key or re-letter this volume: the data
        # disk survives the AIO OS swap, so its resource address and device suffix must not move.
        # device_index 0 renders /dev/sdd, clear of the AMI's own /dev/sdf override above.
        resource_key = "wazuh-data"
        device_index = 0
        volume_type  = "gp3"
        volume_size  = "100"
        iops         = null
        throughput   = null
        snapshot_id  = null
        skip_destroy = false
        tags = {
          Function = "wazuh-data"
        }
      }
    ]

    network_interfaces = [
      {

        description     = "Wazuh AIO (manager+dashboard+indexer) system-specific inbound firewall."
        interface_type  = null
        private_ip      = "10.1.10.20"
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-aio"
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
          },
          {
            description                  = "Wazuh dashboard: HTTPS UI (443) from the deploy subnet"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "10.1.10.0/24"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]

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

  },
  {

    ami = "ami-0ca8a2e788e4c5869"
    # Elastic IP on every system: a DETERMINISTIC routable address. The alternative — relying on the
    # subnet's MapPublicIpOnLaunch auto-assign — is contested between the framework's measured note
    # (e40a792) and windows-wsus's tfvars header, and a proof must not rest on a disputed behaviour.
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Linux; SSH over an SSM session.
    connection_type      = "ssh-ssm"
    hostname             = "sw-lin-ssm"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "ec2-user"
    refresh                    = false
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-agent"
      # THE ANSIBLE-SIDE TRANSPORT DECLARATION. ansible/inventory/aws_ec2.yml derives
      # ansible_connection, ansible_port, ansible_host, windows_password_source and whether the
      # SSM ProxyCommand applies, entirely from this one tag. Step 0 asserts the five-way split.
      #
      # MUST AGREE WITH connection_type ABOVE — nothing enforces it. They state the same fact for
      # two different consumers: connection_type drives Terraform (which user_data is rendered,
      # whether get_password_data is set, and whether the runner-ingress group is attached at all),
      # while this tag drives Ansible, which cannot see a Terraform variable. Disagreement fails
      # in the worst way available: set connection_type to an -ssm value and this tag to a direct
      # one, and Terraform opens no inbound path while Ansible dials the address anyway — a
      # connection timeout, not an error that names the cause.
      #
      # Accepted rather than fixed: the duplication exists only because this one topology
      # deliberately spans five transports to prove them. A real deployment picks a transport and
      # never restates it. The durable fix, if the matrix outlives the PoC, is for the framework to
      # emit the channel as an identity tag so the inventory reads connection_type directly and
      # this tag disappears.
      Connection = "ssm-ssh"
      Backup     = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # The CIS RHEL 8 AMI ships TWO devices: /dev/sda1 (root, handled by root_block_device, which
    # the framework forces encrypted) and a 40 GiB /dev/sdf the image defines and Terraform would
    # otherwise never see. Verified against describe-images: gp3, 40 GiB, 3000 iops, 125 MiB/s,
    # Encrypted=false. Restating it here re-renders the mapping with encrypted = true, which is the
    # only declarative way to encrypt a device the AMI ships unencrypted.
    #
    # This replaces reliance on the account-level enable-ebs-encryption-by-default setting: that
    # works, but it is ambient state no reviewer of this repository can see, and it silently stops
    # protecting the deployment if anyone reverts it.
    #
    # No collision with ebs_block_devices: the framework assigns those suffixes starting at 'd'
    # (/dev/sdd, /dev/sde, ...), so only a THIRD data volume would reach /dev/sdf.
    ami_block_device_overrides = [
      {
        delete_on_termination = true
        device_name           = "/dev/sdf"
        iops                  = "3000"
        throughput            = "125"
        volume_size           = "40"
        volume_type           = "gp3"
      }
    ]

    ebs_block_devices = []

    network_interfaces = [
      {
        description    = "Linux agent reached by SSH through an SSM session; zero inbound."
        interface_type = null
        # null lets AWS pick a free address: six systems share this subnet and hand-allocating
        # every one of them is a collision waiting to happen. Nothing reads the private address
        # before apply — the inventory reads it back off the created interface.
        private_ip      = null
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-agent"
        }

        # DELIBERATELY EMPTY ON EVERY LEG, INCLUDING THE DIRECT ONES. This file declares only
        # PERMANENT rules and knows nothing about the runner. The workflow passes the runner's
        # address as -var "runner_ip=...", and the framework creates ONE group carrying tcp/22,
        # tcp/5986 and ICMP from that /32 and attaches it to every interface. It is destroyed with
        # the stack, so there is no revoke step to strand. Empty (not null) still declares this
        # interface's own group, which is what carries the permanent rules when there are any.
        ingress = []

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

  },
  {

    ami = "ami-0ca8a2e788e4c5869"
    # Elastic IP on every system: a DETERMINISTIC routable address. The alternative — relying on the
    # subnet's MapPublicIpOnLaunch auto-assign — is contested between the framework's measured note
    # (e40a792) and windows-wsus's tfvars header, and a proof must not rest on a disputed behaviour.
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Linux; SSH direct to the Elastic IP.
    connection_type      = "ssh"
    hostname             = "sw-lin-ssh"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "ec2-user"
    refresh                    = false
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-agent"
      # THE ANSIBLE-SIDE TRANSPORT DECLARATION. ansible/inventory/aws_ec2.yml derives
      # ansible_connection, ansible_port, ansible_host, windows_password_source and whether the
      # SSM ProxyCommand applies, entirely from this one tag. Step 0 asserts the five-way split.
      #
      # MUST AGREE WITH connection_type ABOVE — nothing enforces it. They state the same fact for
      # two different consumers: connection_type drives Terraform (which user_data is rendered,
      # whether get_password_data is set, and whether the runner-ingress group is attached at all),
      # while this tag drives Ansible, which cannot see a Terraform variable. Disagreement fails
      # in the worst way available: set connection_type to an -ssm value and this tag to a direct
      # one, and Terraform opens no inbound path while Ansible dials the address anyway — a
      # connection timeout, not an error that names the cause.
      #
      # Accepted rather than fixed: the duplication exists only because this one topology
      # deliberately spans five transports to prove them. A real deployment picks a transport and
      # never restates it. The durable fix, if the matrix outlives the PoC, is for the framework to
      # emit the channel as an identity tag so the inventory reads connection_type directly and
      # this tag disappears.
      Connection = "ssh-direct"
      Backup     = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # The CIS RHEL 8 AMI ships TWO devices: /dev/sda1 (root, handled by root_block_device, which
    # the framework forces encrypted) and a 40 GiB /dev/sdf the image defines and Terraform would
    # otherwise never see. Verified against describe-images: gp3, 40 GiB, 3000 iops, 125 MiB/s,
    # Encrypted=false. Restating it here re-renders the mapping with encrypted = true, which is the
    # only declarative way to encrypt a device the AMI ships unencrypted.
    #
    # This replaces reliance on the account-level enable-ebs-encryption-by-default setting: that
    # works, but it is ambient state no reviewer of this repository can see, and it silently stops
    # protecting the deployment if anyone reverts it.
    #
    # No collision with ebs_block_devices: the framework assigns those suffixes starting at 'd'
    # (/dev/sdd, /dev/sde, ...), so only a THIRD data volume would reach /dev/sdf.
    ami_block_device_overrides = [
      {
        delete_on_termination = true
        device_name           = "/dev/sdf"
        iops                  = "3000"
        throughput            = "125"
        volume_size           = "40"
        volume_type           = "gp3"
      }
    ]

    ebs_block_devices = []

    network_interfaces = [
      {
        description    = "Linux agent reached by SSH direct to its Elastic IP on 22."
        interface_type = null
        # null lets AWS pick a free address: six systems share this subnet and hand-allocating
        # every one of them is a collision waiting to happen. Nothing reads the private address
        # before apply — the inventory reads it back off the created interface.
        private_ip      = null
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-agent"
        }

        # DELIBERATELY EMPTY ON EVERY LEG, INCLUDING THE DIRECT ONES. This file declares only
        # PERMANENT rules and knows nothing about the runner. The workflow passes the runner's
        # address as -var "runner_ip=...", and the framework creates ONE group carrying tcp/22,
        # tcp/5986 and ICMP from that /32 and attaches it to every interface. It is destroyed with
        # the stack, so there is no revoke step to strand. Empty (not null) still declares this
        # interface's own group, which is what carries the permanent rules when there are any.
        ingress = []

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

  },
  {

    ami = "ami-003a141a4ebc8189d"
    # Elastic IP on every system: a DETERMINISTIC routable address. The alternative — relying on the
    # subnet's MapPublicIpOnLaunch auto-assign — is contested between the framework's measured note
    # (e40a792) and windows-wsus's tfvars header, and a proof must not rest on a disputed behaviour.
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Windows OpenSSH, reached through an SSM session.
    connection_type      = "ssh-ssm"
    hostname             = "sw-win-ssm"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "Administrator"
    refresh                    = false
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-agent"
      # THE ANSIBLE-SIDE TRANSPORT DECLARATION. ansible/inventory/aws_ec2.yml derives
      # ansible_connection, ansible_port, ansible_host, windows_password_source and whether the
      # SSM ProxyCommand applies, entirely from this one tag. Step 0 asserts the five-way split.
      #
      # MUST AGREE WITH connection_type ABOVE — nothing enforces it. They state the same fact for
      # two different consumers: connection_type drives Terraform (which user_data is rendered,
      # whether get_password_data is set, and whether the runner-ingress group is attached at all),
      # while this tag drives Ansible, which cannot see a Terraform variable. Disagreement fails
      # in the worst way available: set connection_type to an -ssm value and this tag to a direct
      # one, and Terraform opens no inbound path while Ansible dials the address anyway — a
      # connection timeout, not an error that names the cause.
      #
      # Accepted rather than fixed: the duplication exists only because this one topology
      # deliberately spans five transports to prove them. A real deployment picks a transport and
      # never restates it. The durable fix, if the matrix outlives the PoC, is for the framework to
      # emit the channel as an identity tag so the inventory reads connection_type directly and
      # this tag disappears.
      Connection = "ssm-ssh"
      Backup     = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # Empty because this AMI genuinely defines no non-root EBS device, not as a shortcut.
    # Verified against describe-images: the only Ebs mapping is /dev/sda1 (root), already forced
    # encrypted by root_block_device. Its other mappings (xvdca..xvdcf) are instance-store
    # VirtualName entries, which carry no EBS parameters to override and are inert on t3.medium.
    ami_block_device_overrides = []

    ebs_block_devices = []

    network_interfaces = [
      {
        description    = "Windows agent reached by SSH through an SSM session; zero inbound."
        interface_type = null
        # null lets AWS pick a free address: six systems share this subnet and hand-allocating
        # every one of them is a collision waiting to happen. Nothing reads the private address
        # before apply — the inventory reads it back off the created interface.
        private_ip      = null
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-agent"
        }

        # DELIBERATELY EMPTY ON EVERY LEG, INCLUDING THE DIRECT ONES. This file declares only
        # PERMANENT rules and knows nothing about the runner. The workflow passes the runner's
        # address as -var "runner_ip=...", and the framework creates ONE group carrying tcp/22,
        # tcp/5986 and ICMP from that /32 and attaches it to every interface. It is destroyed with
        # the stack, so there is no revoke step to strand. Empty (not null) still declares this
        # interface's own group, which is what carries the permanent rules when there are any.
        ingress = []

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

  },
  {

    ami = "ami-003a141a4ebc8189d"
    # Elastic IP on every system: a DETERMINISTIC routable address. The alternative — relying on the
    # subnet's MapPublicIpOnLaunch auto-assign — is contested between the framework's measured note
    # (e40a792) and windows-wsus's tfvars header, and a proof must not rest on a disputed behaviour.
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Windows OpenSSH, reached directly on 22.
    connection_type      = "ssh"
    hostname             = "sw-win-ssh"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "Administrator"
    refresh                    = false
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-agent"
      # THE ANSIBLE-SIDE TRANSPORT DECLARATION. ansible/inventory/aws_ec2.yml derives
      # ansible_connection, ansible_port, ansible_host, windows_password_source and whether the
      # SSM ProxyCommand applies, entirely from this one tag. Step 0 asserts the five-way split.
      #
      # MUST AGREE WITH connection_type ABOVE — nothing enforces it. They state the same fact for
      # two different consumers: connection_type drives Terraform (which user_data is rendered,
      # whether get_password_data is set, and whether the runner-ingress group is attached at all),
      # while this tag drives Ansible, which cannot see a Terraform variable. Disagreement fails
      # in the worst way available: set connection_type to an -ssm value and this tag to a direct
      # one, and Terraform opens no inbound path while Ansible dials the address anyway — a
      # connection timeout, not an error that names the cause.
      #
      # Accepted rather than fixed: the duplication exists only because this one topology
      # deliberately spans five transports to prove them. A real deployment picks a transport and
      # never restates it. The durable fix, if the matrix outlives the PoC, is for the framework to
      # emit the channel as an identity tag so the inventory reads connection_type directly and
      # this tag disappears.
      Connection = "ssh-direct"
      Backup     = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # Empty because this AMI genuinely defines no non-root EBS device, not as a shortcut.
    # Verified against describe-images: the only Ebs mapping is /dev/sda1 (root), already forced
    # encrypted by root_block_device. Its other mappings (xvdca..xvdcf) are instance-store
    # VirtualName entries, which carry no EBS parameters to override and are inert on t3.medium.
    ami_block_device_overrides = []

    ebs_block_devices = []

    network_interfaces = [
      {
        description    = "Windows agent reached by SSH direct to its Elastic IP on 22."
        interface_type = null
        # null lets AWS pick a free address: six systems share this subnet and hand-allocating
        # every one of them is a collision waiting to happen. Nothing reads the private address
        # before apply — the inventory reads it back off the created interface.
        private_ip      = null
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-agent"
        }

        # DELIBERATELY EMPTY ON EVERY LEG, INCLUDING THE DIRECT ONES. This file declares only
        # PERMANENT rules and knows nothing about the runner. The workflow passes the runner's
        # address as -var "runner_ip=...", and the framework creates ONE group carrying tcp/22,
        # tcp/5986 and ICMP from that /32 and attaches it to every interface. It is destroyed with
        # the stack, so there is no revoke step to strand. Empty (not null) still declares this
        # interface's own group, which is what carries the permanent rules when there are any.
        ingress = []

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

  },
  {

    ami = "ami-003a141a4ebc8189d"
    # Elastic IP on every system: a DETERMINISTIC routable address. The alternative — relying on the
    # subnet's MapPublicIpOnLaunch auto-assign — is contested between the framework's measured note
    # (e40a792) and windows-wsus's tfvars header, and a proof must not rest on a disputed behaviour.
    associate_public_ip = true
    availability_zone   = "us-east-1a"
    aws_kms_alias       = "aws/ebs"
    # Windows WS-Management. The framework provisions the 5986 HTTPS listener via user_data
    # and enables get_password_data; Ansible decrypts that launch password itself (the
    # framework deliberately does not output it).
    connection_type      = "winrm"
    hostname             = "sw-win-winrm"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    # Null takes the OS default. Every system here sets readiness_gate = false, so the
    # framework builds no gate and none of these is read; they are declared because the
    # all_systems object type requires the key on every entry.
    readiness_command          = null
    readiness_gate             = false
    readiness_private_key_path = null
    readiness_script_dir       = null
    readiness_user             = "Administrator"
    refresh                    = false
    region                     = "us_east_1"
    set_state                  = null
    subnet_id                  = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-agent"
      # THE ANSIBLE-SIDE TRANSPORT DECLARATION. ansible/inventory/aws_ec2.yml derives
      # ansible_connection, ansible_port, ansible_host, windows_password_source and whether the
      # SSM ProxyCommand applies, entirely from this one tag. Step 0 asserts the five-way split.
      #
      # MUST AGREE WITH connection_type ABOVE — nothing enforces it. They state the same fact for
      # two different consumers: connection_type drives Terraform (which user_data is rendered,
      # whether get_password_data is set, and whether the runner-ingress group is attached at all),
      # while this tag drives Ansible, which cannot see a Terraform variable. Disagreement fails
      # in the worst way available: set connection_type to an -ssm value and this tag to a direct
      # one, and Terraform opens no inbound path while Ansible dials the address anyway — a
      # connection timeout, not an error that names the cause.
      #
      # Accepted rather than fixed: the duplication exists only because this one topology
      # deliberately spans five transports to prove them. A real deployment picks a transport and
      # never restates it. The durable fix, if the matrix outlives the PoC, is for the framework to
      # emit the channel as an identity tag so the inventory reads connection_type directly and
      # this tag disappears.
      Connection = "winrm-direct"
      Backup     = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    # Empty because this AMI genuinely defines no non-root EBS device, not as a shortcut.
    # Verified against describe-images: the only Ebs mapping is /dev/sda1 (root), already forced
    # encrypted by root_block_device. Its other mappings (xvdca..xvdcf) are instance-store
    # VirtualName entries, which carry no EBS parameters to override and are inert on t3.medium.
    ami_block_device_overrides = []

    ebs_block_devices = []

    network_interfaces = [
      {
        description    = "Windows agent reached by WinRM/HTTPS direct to its Elastic IP on 5986."
        interface_type = null
        # null lets AWS pick a free address: six systems share this subnet and hand-allocating
        # every one of them is a collision waiting to happen. Nothing reads the private address
        # before apply — the inventory reads it back off the created interface.
        private_ip      = null
        security_groups = []

        tags = {
          # Environment is deliberately absent: the framework writes it (along with Name,
          # ManagedBy, Repository, RepositoryId, CommitSha, RunId, OS, Index, DeviceName and
          # Backup) and rejects any consumer map that sets one, in any letter case.
          System = "wazuh"
          Role   = "wazuh-agent"
        }

        # DELIBERATELY EMPTY ON EVERY LEG, INCLUDING THE DIRECT ONES. This file declares only
        # PERMANENT rules and knows nothing about the runner. The workflow passes the runner's
        # address as -var "runner_ip=...", and the framework creates ONE group carrying tcp/22,
        # tcp/5986 and ICMP from that /32 and attaches it to every interface. It is destroyed with
        # the stack, so there is no revoke step to strand. Empty (not null) still declares this
        # interface's own group, which is what carries the permanent rules when there are any.
        ingress = []

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

  },

]

all_databases      = []
all_load_balancers = []
