resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node_name
  description = var.description
  tags        = sort(var.tags)

  bios          = "seabios"
  scsi_hardware = "virtio-scsi-pci"
  on_boot       = true
  started       = true

  # Prefer ACPI stop if qemu-guest-agent is stuck during destroy.
  stop_on_destroy = true

  clone {
    vm_id        = var.template_id
    datastore_id = var.datastore_id
    full         = true
    retries      = var.clone_retries
  }

  agent {
    enabled = true
    timeout = "15m"
    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = var.mac_address
  }

  # Native Proxmox cloud-init (no Snippets datastore, so API token is enough).
  # upgrade=true is rejected unless the API user is root@pam.
  # IPv4 is always DHCP; pin MAC and map leases outside Terraform.
  initialization {
    datastore_id = var.datastore_id
    upgrade      = false

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.ssh_username
      keys     = [trimspace(var.ssh_public_key)]
    }
  }

  operating_system {
    type = "l26"
  }
}

locals {
  iface_names = try(proxmox_virtual_environment_vm.this.network_interface_names, [])
  iface_addrs = try(proxmox_virtual_environment_vm.this.ipv4_addresses, [])

  usable_ipv4 = flatten([
    for i, name in local.iface_names : [
      for ip in try(local.iface_addrs[i], []) : ip
      if ip != "127.0.0.1"
      && !startswith(ip, "169.254.")
      && !startswith(ip, "10.42.")
      && !startswith(ip, "10.43.")
      && length(regexall("^(lo|docker|flannel|cni|veth|cilium|calico|tunl|wg)", name)) == 0
    ]
  ])
}
