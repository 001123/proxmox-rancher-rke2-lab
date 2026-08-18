resource "terraform_data" "validate_worker_macs" {
  input = {
    worker_count = var.worker_count
    macs         = var.rke2_worker_mac_addresses
  }

  lifecycle {
    precondition {
      condition     = contains([0, var.worker_count], length(var.rke2_worker_mac_addresses))
      error_message = "rke2_worker_mac_addresses must be empty (auto) or have exactly worker_count entries."
    }
  }
}

module "mgmt" {
  source = "./modules/proxmox_vm"

  name           = "rancher-mgmt"
  description    = "Rancher management (k3s + Helm)"
  node_name      = var.proxmox_node
  template_id    = var.template_id
  datastore_id   = var.datastore_id
  bridge         = var.bridge
  cpu_cores      = var.mgmt_vcpus
  cpu_type       = var.cpu_type
  memory_mb      = var.mgmt_memory_mb
  disk_size_gb   = var.mgmt_disk_gb
  ssh_username   = var.ssh_user
  ssh_public_key = local.ssh_public_key
  tags           = concat(var.vm_tags, ["mgmt"])
  mac_address    = var.mgmt_mac_address
}

module "rke2_control_plane" {
  source = "./modules/proxmox_vm"

  name           = "rke2-cp-01"
  description    = "RKE2 custom cluster etcd + control-plane"
  node_name      = var.proxmox_node
  template_id    = var.template_id
  datastore_id   = var.datastore_id
  bridge         = var.bridge
  cpu_cores      = var.rke2_vcpus
  cpu_type       = var.cpu_type
  memory_mb      = var.rke2_memory_mb
  disk_size_gb   = var.rke2_disk_gb
  ssh_username   = var.ssh_user
  ssh_public_key = local.ssh_public_key
  tags           = concat(var.vm_tags, ["rke2", "control-plane"])
  mac_address    = var.rke2_cp_mac_address
}

module "rke2_workers" {
  source = "./modules/proxmox_vm"
  count  = var.worker_count

  name           = format("rke2-wk-%02d", count.index + 1)
  description    = "RKE2 custom cluster worker"
  node_name      = var.proxmox_node
  template_id    = var.template_id
  datastore_id   = var.datastore_id
  bridge         = var.bridge
  cpu_cores      = var.rke2_vcpus
  cpu_type       = var.cpu_type
  memory_mb      = var.rke2_worker_memory_mb
  disk_size_gb   = var.rke2_disk_gb
  ssh_username   = var.ssh_user
  ssh_public_key = local.ssh_public_key
  tags           = concat(var.vm_tags, ["rke2", "worker"])
  mac_address    = try(var.rke2_worker_mac_addresses[count.index], null)
}
