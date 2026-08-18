variable "proxmox_endpoint" {
  type        = string
  default     = null
  description = "Proxmox API URL, e.g. https://192.168.100.252:8006/. Null = PROXMOX_VE_ENDPOINT."

  validation {
    condition     = var.proxmox_endpoint == null || endswith(var.proxmox_endpoint, "/")
    error_message = "proxmox_endpoint must end with / (do not append /api2/json)."
  }
}

variable "proxmox_api_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "API token user@realm!tokenid=uuid. Null = PROXMOX_VE_API_TOKEN."
}

variable "proxmox_insecure" {
  type        = bool
  default     = true
  description = "Skip TLS verify for the Proxmox API (self-signed lab cert). Also PROXMOX_VE_INSECURE."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name that will host the VMs (qm list / UI node name)."
}

variable "template_id" {
  type        = number
  description = "VMID of the Ubuntu 24.04 cloud-init template (created by scripts/create-ubuntu-24.04-template.sh)."
}

variable "datastore_id" {
  type        = string
  default     = "local-lvm"
  description = "Datastore for cloned disks and the cloud-init drive."
}

variable "bridge" {
  type        = string
  default     = "vmbr0"
  description = "Linux bridge for VM NICs."
}

variable "cpu_type" {
  type        = string
  default     = "x86-64-v2-AES"
  description = "QEMU CPU type. Use host if nested virt / older CPU flags are required."
}

variable "ssh_user" {
  type        = string
  default     = "ubuntu"
  description = "Cloud-init / SSH user (Ubuntu cloud image default)."
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key injected via cloud-init."
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the matching private key used by remote-exec (not stored in state)."
}

variable "rancher_bootstrap_password" {
  type        = string
  sensitive   = true
  description = "Initial Rancher admin password (Helm bootstrapPassword and rancher2_bootstrap). Use 12+ characters."

  validation {
    condition     = length(var.rancher_bootstrap_password) >= 12
    error_message = "Rancher bootstrap password must be at least 12 characters."
  }
}

variable "rancher_chart_version" {
  type        = string
  default     = ""
  description = "Pin rancher-latest/rancher chart version. Empty = latest from the repo."
}

variable "k3s_version" {
  type        = string
  default     = "v1.36.3+k3s1"
  description = "k3s version on rancher-mgmt (INSTALL_K3S_VERSION). Pin to a version your Rancher release supports (2.15 → 1.34–1.36)."
}

variable "rke2_kubernetes_version" {
  type        = string
  default     = "v1.36.3+rke2r1"
  description = "RKE2 version string for rancher2_cluster_v2. Must exist in the installed Rancher (Create → Custom)."
}

variable "cluster_name" {
  type        = string
  default     = "lab-rke2"
  description = "Name of the custom RKE2 cluster in Rancher."
}

variable "worker_count" {
  type        = number
  default     = 2
  description = "Number of RKE2 worker VMs."
}

variable "mgmt_vcpus" {
  type        = number
  default     = 4
  description = "vCPU count for rancher-mgmt."
}

variable "mgmt_memory_mb" {
  type        = number
  default     = 8192
  description = "RAM in MiB for rancher-mgmt. 4096 often OOMs."
}

variable "mgmt_disk_gb" {
  type        = number
  default     = 40
  description = "scsi0 size in GiB for rancher-mgmt (grown from the template disk)."
}

variable "rke2_vcpus" {
  type        = number
  default     = 2
  description = "vCPU count for each RKE2 node."
}

variable "rke2_memory_mb" {
  type        = number
  default     = 4096
  description = "RAM in MiB for each RKE2 node."
}

variable "rke2_disk_gb" {
  type        = number
  default     = 40
  description = "scsi0 size in GiB for each RKE2 node."
}

variable "vm_tags" {
  type        = list(string)
  default     = ["terraform", "rancher-lab"]
  description = "Proxmox tags applied to every VM (provider sorts them)."
}

variable "mgmt_mac_address" {
  type        = string
  default     = null
  description = "MAC for rancher-mgmt net0 (e.g. BC:24:11:00:00:10). Null = Proxmox generates one."

  validation {
    condition     = var.mgmt_mac_address == null || can(regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", var.mgmt_mac_address))
    error_message = "mgmt_mac_address must be colon-separated hex, e.g. BC:24:11:00:00:10."
  }
}

variable "rke2_cp_mac_address" {
  type        = string
  default     = null
  description = "MAC for rke2-cp-01 net0. Null = Proxmox generates one."

  validation {
    condition     = var.rke2_cp_mac_address == null || can(regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", var.rke2_cp_mac_address))
    error_message = "rke2_cp_mac_address must be colon-separated hex, e.g. BC:24:11:00:00:11."
  }
}

variable "rke2_worker_mac_addresses" {
  type        = list(string)
  default     = []
  description = "MAC per worker net0. Empty = Proxmox generates them. Length must equal worker_count."

  validation {
    condition = alltrue([
      for mac in var.rke2_worker_mac_addresses :
      can(regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", mac))
    ])
    error_message = "Each rke2_worker_mac_addresses entry must be colon-separated hex."
  }
}
