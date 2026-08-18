variable "name" {
  type        = string
  description = "VM name (must be a valid DNS name)."
}

variable "node_name" {
  type        = string
  description = "Proxmox node to place the VM on."
}

variable "template_id" {
  type        = number
  description = "Source template VMID."
}

variable "datastore_id" {
  type        = string
  description = "Datastore for the cloned disk and cloud-init drive."
}

variable "bridge" {
  type        = string
  description = "Linux bridge for net0."
}

variable "cpu_cores" {
  type        = number
  description = "Number of vCPU cores."
}

variable "cpu_type" {
  type        = string
  description = "QEMU CPU type (e.g. x86-64-v2-AES or host)."
}

variable "memory_mb" {
  type        = number
  description = "Dedicated RAM in MiB."
}

variable "disk_size_gb" {
  type        = number
  description = "scsi0 size in GiB after clone."
}

variable "ssh_username" {
  type        = string
  description = "Cloud-init user."
}

variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key injected via cloud-init."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Proxmox VM tags. The module sorts them to avoid perpetual diffs."
}

variable "description" {
  type        = string
  default     = "Managed by Terraform"
  description = "VM description shown in Proxmox."
}

variable "clone_retries" {
  type        = number
  default     = 3
  description = "Proxmox clone retries (helps when cloning several VMs at once)."
}

variable "mac_address" {
  type        = string
  default     = null
  description = "MAC for net0 (e.g. BC:24:11:00:00:10). Null = Proxmox generates one."

  validation {
    condition     = var.mac_address == null || can(regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", var.mac_address))
    error_message = "mac_address must be colon-separated hex, e.g. BC:24:11:00:00:10."
  }
}

