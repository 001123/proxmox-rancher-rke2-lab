# Credentials stay out of git. Set on the laptop before plan/apply:
#   PROXMOX_VE_ENDPOINT   (must end with /)
#   PROXMOX_VE_API_TOKEN  (user@realm!tokenid=uuid)
#   PROXMOX_VE_INSECURE   (true for the default self-signed PVE cert)
#
# Docs: https://registry.terraform.io/providers/bpg/proxmox/0.111.1/docs
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
}

# rancher2 is configured twice: bootstrap (first password) then admin (API token).
# api_url is only known after guest-agent reports the DHCP IPv4.
# First apply is often two-stage (see README). Docs:
#   https://registry.terraform.io/providers/rancher/rancher2/latest/docs
provider "rancher2" {
  alias     = "bootstrap"
  api_url   = local.rancher_url
  bootstrap = true
  insecure  = true
  # Default 120s is too short: local cluster becomes Connected after /ping,
  # and rancher2_bootstrap still waits for condition Updated.
  timeout = "15m"
}

provider "rancher2" {
  alias     = "admin"
  api_url   = rancher2_bootstrap.admin.url
  token_key = rancher2_bootstrap.admin.token
  insecure  = true
  timeout   = "15m"
}
