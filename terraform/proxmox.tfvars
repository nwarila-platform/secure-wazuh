# Proxmox target inputs for secure-wazuh (consumed by proxmox-vm-terraform-framework).
#
# Secrets and operator-local values stay out of this file:
# - proxmox_hostname
# - proxmox_api_token_id
# - proxmox_api_token_secret
# - proxmox_cloud_init_user_name
# - proxmox_cloud_init_user_password
# - proxmox_cloud_init_user_public_key

# Lab/on-prem Proxmox exposes its API over a self-signed cert; skip verification for the
# provider handshake. Set false wherever the Proxmox API presents a CA-trusted certificate.
proxmox_skip_tls_verify = true

all_systems = [
  {
    name      = "wazuh-aio"
    node_name = "tcnhq-prxmx01"
    pool_id   = "tcn-infrastructure"
    # RHEL/Rocky 8 ONLY: bootstrap.yml hard-asserts distribution_major_version == 8 (platform-
    # python 3.6 carries the libselinux/dnf/firewalld bindings the roles need). Matches aws.tfvars.
    template  = "rocky_linux_8_x64"
    vm_id     = 1000

    cpu = {
      cores   = 4
      sockets = 1
      type    = "host"
    }

    memory = {
      dedicated = 8192
    }

    boot_order    = ["scsi2"]
    machine       = "q35"
    scsi_hardware = "virtio-scsi-single"

    disks = [
      {
        interface    = "scsi2"
        size         = 100
        datastore_id = "nvme-pool"
        file_format  = "raw"
        iothread     = true
        ssd          = true
      },
      {
        interface    = "scsi4"
        serial       = "wazuh-data"
        size         = 256
        datastore_id = "nvme-pool"
        file_format  = "raw"
        iothread     = true
        persist_disk = true
        ssd          = true
      }
    ]

    initialization = {
      datastore_id = "nvme-pool"
      dns          = null
      servers      = ["1.1.1.1", "8.8.8.8"]
    }

    network_devices = [
      {
        bridge             = "vmbr0"
        model              = "virtio"
        mtu                = 1492
        queues             = 1
        vlan_id            = 212
        ipv4_address       = "10.69.112.72"
        ipv4_prefix_length = 24
        ipv4_gateway       = "10.69.112.1"
      }
    ]

    agent = {
      enabled = true
    }

    ansible = {
      groups = [
        "wazuh_indexers",
        "wazuh_servers",
        "wazuh_dashboards",
      ]

      host_vars = {
        ansible_user                 = "ansible_admin"
        ansible_ssh_private_key_file = "/root/.ssh/id_rsa_wazuh"
        wazuh_data_device            = "/dev/disk/by-id/scsi-SQEMU_QEMU_HARDDISK_wazuh-data"
        wazuh_data_mount             = "/mnt/data"
        wazuh_data_fstype            = "xfs"
      }
    }

    tags    = ["wazuh", "aio"]
    on_boot = true
    started = true
  }
]
