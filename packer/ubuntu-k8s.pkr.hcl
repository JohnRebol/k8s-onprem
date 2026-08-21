packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, supplied via PKR_VAR_proxmox_url."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID, supplied via PKR_VAR_proxmox_api_token_id."
}

variable "proxmox_api_token_secret" {
  type        = string
  sensitive   = true
  description = "Proxmox API token secret, supplied via PKR_VAR_proxmox_api_token_secret."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node used for the build."
}

variable "datastore_id" {
  type        = string
  description = "Proxmox datastore for the image disk."
}

variable "iso_datastore_id" {
  type        = string
  description = "Proxmox datastore the boot ISO is downloaded to."
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge."
}

variable "ubuntu_version" {
  type        = string
  default     = "26.04"
  description = "Ubuntu release used for the golden image."
}

variable "ubuntu_iso_url" {
  type        = string
  description = "Direct URL to the Ubuntu Server ISO."
}

variable "ubuntu_iso_checksum" {
  type        = string
  description = "Ubuntu ISO checksum, either sha256:<digest> or file:<url-to-SHA256SUMS>."
}

variable "ssh_username" {
  type        = string
  description = "SSH user created by autoinstall."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key installed for the build user, supplied via PKR_VAR_ssh_public_key."
}

variable "ssh_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt(3) password hash required by Ubuntu autoinstall, supplied via PKR_VAR_ssh_password_hash."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the matching SSH private key, supplied via PKR_VAR_ssh_private_key_file."
}

variable "k8s_template_vm_id" {
  type        = number
  default     = 9000
  description = "VM ID assigned to the Kubernetes golden image."
}

variable "kubernetes_repo_version" {
  type        = string
  default     = "v1.35"
  description = "Kubernetes apt repository version."
}

variable "hold_kubernetes_packages" {
  type        = bool
  default     = true
  description = "Hold kubelet, kubeadm, and kubectl after installation."
}

source "proxmox-iso" "ubuntu-k8s" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_id                = var.k8s_template_vm_id
  vm_name              = "k8s-ubuntu-${var.ubuntu_version}-golden"
  template_name        = "k8s-ubuntu-${var.ubuntu_version}-golden"
  template_description = "Kubernetes golden image for the on-premises cluster"
  qemu_agent           = true
  scsi_controller      = "virtio-scsi-single"
  bios                 = "seabios"
  os                   = "l26"
  cores                = 8
  memory               = 16384
  sockets              = 1
  cpu_type             = "host"
  network_adapters {
    model    = "virtio"
    bridge   = var.network_bridge
    firewall = true
  }
  disks {
    disk_size    = "20G"
    storage_pool = var.datastore_id
    type         = "scsi"
    format       = "raw"
    cache_mode   = "none"
    discard      = true
    io_thread    = true
    ssd          = true
  }

  boot_iso {
    type             = "scsi"
    iso_url          = var.ubuntu_iso_url
    iso_checksum     = var.ubuntu_iso_checksum
    iso_storage_pool = var.iso_datastore_id
    iso_download_pve = true
    unmount          = true
  }

  http_content = {
    "/meta-data" = file("${path.root}/http/meta-data")
    "/user-data" = templatefile("${path.root}/http/user-data", {
      ssh_username      = var.ssh_username
      ssh_public_key    = var.ssh_public_key
      ssh_password_hash = var.ssh_password_hash
    })
  }
  boot_wait = "5s"
  boot_command = [
    "<wait><wait><esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>",
  ]

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "30m"
}

build {
  name    = "ubuntu-k8s"
  sources = ["source.proxmox-iso.ubuntu-k8s"]

  provisioner "shell" {
    script            = "scripts/provision-k8s.sh"
    execute_command   = "chmod +x {{ .Path }}; sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true
    environment_vars = [
      "KUBERNETES_REPO_VERSION=${var.kubernetes_repo_version}",
      "HOLD_KUBERNETES_PACKAGES=${var.hold_kubernetes_packages}",
    ]
  }
}
