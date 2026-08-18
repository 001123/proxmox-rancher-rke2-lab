terraform {
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.111.1"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 14.1"
    }
  }
}
