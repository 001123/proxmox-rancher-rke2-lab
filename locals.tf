locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # rancher2 api_url is known after guest-agent reports the DHCP IPv4.
  mgmt_ipv4_host   = module.mgmt.ipv4_address
  rancher_hostname = local.mgmt_ipv4_host != null ? "rancher.${local.mgmt_ipv4_host}.sslip.io" : null
  rancher_url      = local.rancher_hostname != null ? "https://${local.rancher_hostname}" : null
}
