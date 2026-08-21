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
