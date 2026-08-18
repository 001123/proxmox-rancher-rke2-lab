resource "terraform_data" "install_rancher" {
  triggers_replace = [
    module.mgmt.vm_id,
    module.mgmt.ipv4_address,
    var.rancher_bootstrap_password,
    var.k3s_version,
    var.rancher_chart_version,
    filesha256("${path.module}/scripts/install-k3s-rancher.sh"),
  ]

  connection {
    type        = "ssh"
    host        = module.mgmt.ipv4_address
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "30m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/install-k3s-rancher.sh"
    destination = "/tmp/install-k3s-rancher.sh"
  }

  provisioner "file" {
    content = jsonencode({
      k3s_version           = var.k3s_version
      rancher_hostname      = local.rancher_hostname
      bootstrap_password    = var.rancher_bootstrap_password
      rancher_chart_version = var.rancher_chart_version
    })
    destination = "/tmp/rancher-install.json"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install-k3s-rancher.sh",
      "sudo /tmp/install-k3s-rancher.sh /tmp/rancher-install.json",
    ]
  }
}

resource "rancher2_bootstrap" "admin" {
  provider = rancher2.bootstrap

  initial_password = var.rancher_bootstrap_password
  password         = var.rancher_bootstrap_password

  depends_on = [terraform_data.install_rancher]
}
