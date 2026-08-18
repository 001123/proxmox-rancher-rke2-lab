resource "rancher2_cluster_v2" "rke2" {
  provider = rancher2.admin

  name               = var.cluster_name
  kubernetes_version = var.rke2_kubernetes_version

  depends_on = [rancher2_bootstrap.admin]
}

locals {
  rke2_insecure_node_command = rancher2_cluster_v2.rke2.cluster_registration_token[0].insecure_node_command
}

resource "terraform_data" "join_control_plane" {
  triggers_replace = [
    rancher2_cluster_v2.rke2.cluster_v1_id,
    module.rke2_control_plane.vm_id,
    module.rke2_control_plane.ipv4_address,
    filesha256("${path.module}/scripts/join-rke2-node.sh"),
  ]

  connection {
    type        = "ssh"
    host        = module.rke2_control_plane.ipv4_address
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/join-rke2-node.sh"
    destination = "/tmp/join-rke2-node.sh"
  }

  provisioner "file" {
    content     = "${local.rke2_insecure_node_command} --etcd --controlplane\n"
    destination = "/tmp/rke2-join-command"
  }

  provisioner "file" {
    content = jsonencode({
      rancher_hostname = local.rancher_hostname
      rancher_ip       = module.mgmt.ipv4_address
    })
    destination = "/tmp/rancher-endpoint.json"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join-rke2-node.sh",
      "sudo /tmp/join-rke2-node.sh /tmp/rke2-join-command",
    ]
  }
}

resource "terraform_data" "join_workers" {
  count = var.worker_count

  triggers_replace = [
    rancher2_cluster_v2.rke2.cluster_v1_id,
    module.rke2_workers[count.index].vm_id,
    module.rke2_workers[count.index].ipv4_address,
    filesha256("${path.module}/scripts/join-rke2-node.sh"),
  ]

  connection {
    type        = "ssh"
    host        = module.rke2_workers[count.index].ipv4_address
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/join-rke2-node.sh"
    destination = "/tmp/join-rke2-node.sh"
  }

  provisioner "file" {
    content     = "${local.rke2_insecure_node_command} --worker\n"
    destination = "/tmp/rke2-join-command"
  }

  provisioner "file" {
    content = jsonencode({
      rancher_hostname = local.rancher_hostname
      rancher_ip       = module.mgmt.ipv4_address
    })
    destination = "/tmp/rancher-endpoint.json"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join-rke2-node.sh",
      "sudo /tmp/join-rke2-node.sh /tmp/rke2-join-command",
    ]
  }

  depends_on = [terraform_data.join_control_plane]
}
