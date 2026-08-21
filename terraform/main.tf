# Deploys the Kubernetes cluster by cloning the Packer golden image (template
# 9000) once per node, then bootstrapping kubeadm on top.
#
# Read order: this file creates the VMs and wires up the bootstrap; variables.tf
# defines the inputs; scripts/ holds what actually runs on the nodes.

locals {
  # Derives sequential worker IPs by incrementing the last octet of
  # worker_ip_start: "10.10.3.241" with worker_count = 3 becomes .241/.242/.243.
  #
  # This only walks the final octet, so a run that would cross a .255 boundary
  # produces an invalid address rather than rolling into the next subnet. Fine
  # for a handful of nodes; if the cluster ever grows past that, list the IPs
  # explicitly instead.
  worker_ip_octets = split(".", var.worker_ip_start)
  worker_ips = [
    for i in range(var.worker_count) :
    join(".", concat(
      slice(local.worker_ip_octets, 0, 3),
      [tostring(tonumber(local.worker_ip_octets[3]) + i)]
    ))
  ]
}

# The control-plane node: runs the Kubernetes API server, scheduler, and etcd.
# Created first because the workers need a cluster to join.
resource "proxmox_virtual_environment_vm" "controller" {
  name      = "k8s-controller"
  node_name = var.proxmox_node
  vm_id     = var.controller_vm_id

  # full = true copies the disk outright. A linked clone would be faster and
  # smaller but stays dependent on the template forever -- meaning the template
  # could not be rebuilt or deleted without breaking live nodes.
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
    type  = var.cpu_type
  }

  memory {
    dedicated = var.controller_memory
  }

  network_device {
    bridge = var.network_bridge
  }

  # cloud-init. Proxmox writes these values to a small virtual CD-ROM attached
  # to the VM; on first boot the guest reads it and applies its own hostname,
  # IP, DNS, and SSH key. That is how one identical template becomes four
  # differently-configured nodes.
  #
  # This only works because the image was "unsealed" during the Packer build --
  # Ubuntu's installer otherwise disables cloud-init after autoinstall, and the
  # nodes would silently come up on DHCP with the template's hostname. See the
  # cloud-init section of scripts/provision-k8s.sh.
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

  # How the provisioners below reach this node once it boots.
  connection {
    type        = "ssh"
    host        = var.controller_ip
    user        = var.ssh_username
    private_key = file(var.ssh_private_key_file)
    timeout     = "5m"
  }

  # Provisioners run ONCE, when the resource is first created -- never on later
  # applies. Changing these scripts therefore does nothing to a node that
  # already exists; the node has to be recreated with
  # `terraform apply -replace=...` for the new version to run. See README.md.
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
#
# A node joins a cluster by presenting a short-lived bootstrap token plus a hash
# of the cluster's CA certificate. Both are only known after `kubeadm init` has
# run, so they cannot be written into this config ahead of time -- they have to
# be read back off the control plane at apply time and handed to the workers.
#
# terraform_data is a built-in resource that exists purely to hang provisioners
# and ordering off of; it manages no real infrastructure.
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

# The worker nodes, where application workloads actually run.
#
# count creates worker_count copies of this resource, addressed as worker[0],
# worker[1], ... count.index is the 0-based position, used to give each one a
# distinct name, VM ID, and IP.
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
    type  = var.cpu_type
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
