locals {
  worker_ip_octets = split(".", var.worker_ip_start)
  worker_ips = [
    for i in range(var.worker_count) :
    join(".", concat(
      slice(local.worker_ip_octets, 0, 3),
      [tostring(tonumber(local.worker_ip_octets[3]) + i)]
    ))
  ]
}

resource "proxmox_virtual_environment_vm" "controller" {
  name      = "k8s-controller"
  node_name = var.proxmox_node
  vm_id     = var.controller_vm_id

  clone {
    vm_id     = var.k8s_template_vm_id
    node_name = var.proxmox_node
    full      = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.controller_cores
  }

  memory {
    dedicated = var.controller_memory
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${var.controller_ip}/${var.network_cidr_suffix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ssh_username
      keys     = [var.ssh_public_key]
    }
  }

  operating_system {
    type = "l26"
  }

  connection {
    type        = "ssh"
    host        = var.controller_ip
    user        = var.ssh_username
    private_key = file(var.ssh_private_key_file)
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/init-control-plane.sh.tpl", {
      username         = var.ssh_username
      control_plane_ip = var.controller_ip
      pod_network_cidr = var.pod_network_cidr
      calico_version   = var.calico_version
    })
    destination = "/tmp/init-control-plane.sh"
  }

  provisioner "remote-exec" {
    inline = ["sudo bash /tmp/init-control-plane.sh"]
  }
}

# Pull the kubeadm join command off the control-plane node so workers can join
# without a hardcoded token.
resource "terraform_data" "join_command" {
  # Ordering via depends_on alone would only cover the first creation. Keying
  # on the control-plane's id means a rebuilt control plane (new token, new CA
  # hash) refetches, instead of leaving workers to join a cluster that no
  # longer exists.
  triggers_replace = [proxmox_virtual_environment_vm.controller.id]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${path.module}/scripts/fetch-join-command.sh ${var.ssh_username} ${var.controller_ip} ${var.ssh_private_key_file} ${path.module}/kubeadm-join-command.sh"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count = var.worker_count

  name      = "k8s-worker-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = var.worker_vm_id_start + count.index

  clone {
    vm_id     = var.k8s_template_vm_id
    node_name = var.proxmox_node
    full      = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.worker_cores
  }

  memory {
    dedicated = var.worker_memory
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index]}/${var.network_cidr_suffix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ssh_username
      keys     = [var.ssh_public_key]
    }
  }

  operating_system {
    type = "l26"
  }
}

# Joining is split out of the worker resource itself so the VMs don't inherit
# the control plane's dependency. A worker's *existence* doesn't depend on the
# cluster -- only its join does. Keeping them separate lets all four VMs clone
# and boot in parallel while the control plane initializes, instead of leaving
# the workers idle through kubeadm init and the CNI rollout.
resource "terraform_data" "worker_join" {
  count = var.worker_count

  triggers_replace = [
    proxmox_virtual_environment_vm.worker[count.index].id,
    terraform_data.join_command.id,
  ]

  connection {
    type        = "ssh"
    host        = local.worker_ips[count.index]
    user        = var.ssh_username
    private_key = file(var.ssh_private_key_file)
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/kubeadm-join-command.sh"
    destination = "/tmp/kubeadm-join-command.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # Same reason as the control plane: kubeadm registers the node under its
      # hostname, so don't join until cloud-init has finished setting it.
      "cloud-init status --wait >/dev/null 2>&1 || true",
      "sudo bash /tmp/kubeadm-join-command.sh",
    ]
  }
}
