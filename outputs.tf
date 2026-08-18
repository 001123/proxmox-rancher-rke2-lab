output "rancher_url" {
  description = "Rancher UI (sslip.io hostname derived from rancher-mgmt IPv4)."
  value       = local.rancher_url
}

output "rancher_hostname" {
  value = local.rancher_hostname
}

output "mgmt_ip" {
  value = module.mgmt.ipv4_address
}

output "mgmt_mac_address" {
  value = module.mgmt.mac_address
}

output "rke2_control_plane_ip" {
  value = module.rke2_control_plane.ipv4_address
}

output "rke2_control_plane_mac_address" {
  value = module.rke2_control_plane.mac_address
}

output "rke2_worker_ips" {
  value = [for w in module.rke2_workers : w.ipv4_address]
}

output "rke2_worker_mac_addresses" {
  value = [for w in module.rke2_workers : w.mac_address]
}

output "cluster_name" {
  value = rancher2_cluster_v2.rke2.name
}

output "cluster_id" {
  value = rancher2_cluster_v2.rke2.cluster_v1_id
}

output "kubectl_hint" {
  description = "After the cluster is Active, kubeconfig is in Terraform state (sensitive)."
  value       = "terraform output -raw rke2_kube_config > kubeconfig-rke2.yaml && export KUBECONFIG=$PWD/kubeconfig-rke2.yaml"
}

output "rke2_kube_config" {
  description = "Kubeconfig from Rancher. Empty until the custom cluster reports connected; re-apply or refresh after nodes join."
  value       = rancher2_cluster_v2.rke2.kube_config
  sensitive   = true
}
