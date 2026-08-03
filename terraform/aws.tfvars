# 
environment = "dev"

# 
readiness_linux_script_dir = "/home/ec2-user"

# 
readiness_private_key_paths = {
  "nwarila-ec2-key" = "/root/.ssh/nwarila-ec2-key.pem"
}

all_systems = [
  {

    ami                  = "ami-0ca8a2e788e4c5869"
    associate_public_ip  = false
    availability_zone    = "us-east-1a"
    aws_kms_alias        = "aws/ebs"
    hostname             = "secure-wazuh-poc"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "m6i.xlarge"
    key_name             = "nwarila-ec2-key"
    readiness_gate       = false
    readiness_user       = "ec2-user"
    refresh              = true
    region               = "us_east_1"
    set_state            = null
    subnet_id            = "subnet-0e1c8aae192deff26"

    tags = {
      Function = "wazuh-aio"
      Backup   = false #
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }

    ebs_block_devices = [
      {
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

    ami                  = "ami-0ca8a2e788e4c5869"
    associate_public_ip  = false
    availability_zone    = "us-east-1a"
    aws_kms_alias        = "aws/ebs"
    hostname             = "secure-wazuh-poc-agent-linux"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    readiness_gate       = false
    readiness_user       = "ec2-user"
    refresh              = false
    region               = "us_east_1"
    set_state            = null
    subnet_id            = "subnet-0e1c8aae192deff26"

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

    ebs_block_devices = []

    network_interfaces = [
      {
        description     = "Linux Wazuh agent system-specific zero-inbound firewall."
        interface_type  = null
        private_ip      = "10.1.10.21"
        security_groups = []

        tags = {
          Environment = "dev"
          System      = "wazuh"
          Role        = "wazuh-agent"
        }

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

    ami                  = "ami-003a141a4ebc8189d"
    associate_public_ip  = false
    availability_zone    = "us-east-1a"
    aws_kms_alias        = "aws/ebs"
    hostname             = "secure-wazuh-poc-agent-win"
    iam_instance_profile = "nwarila-ec2-profile"
    imds_hop_limit       = 1
    instance_type        = "t3.medium"
    key_name             = "nwarila-ec2-key"
    readiness_gate       = false
    readiness_user       = "Administrator"
    refresh              = false
    region               = "us_east_1"
    set_state            = null
    subnet_id            = "subnet-0e1c8aae192deff26"

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

    ebs_block_devices = []

    network_interfaces = [
      {
        private_ip      = "10.1.10.22"
        security_groups = []
        description     = "Windows Wazuh agent system-specific zero-inbound firewall."
        interface_type  = null
        tags = {
          Environment = "dev"
          System      = "wazuh"
          Role        = "wazuh-agent"
        }

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

  }
]

all_databases      = []
all_load_balancers = []
