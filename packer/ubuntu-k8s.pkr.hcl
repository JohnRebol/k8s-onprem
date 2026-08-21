# Builds the Kubernetes "golden image": a Proxmox VM template with containerd
# and the Kubernetes tooling preinstalled, which Terraform then clones to create
# cluster nodes.
#
# The build is: create a throwaway VM -> boot the Ubuntu installer -> let
# autoinstall run unattended (http/user-data) -> run scripts/provision-k8s.sh
# over SSH -> shut down -> convert the VM into a template.
#
# Building an image once and cloning it is what keeps node creation fast and
# identical every time; the alternative is installing the same packages on
# every node at boot, which is slower and drifts as upstream packages change.

packer {
  required_plugins {
    proxmox = {
      source = "github.com/hashicorp/proxmox"
      # ">=" allows newer plugin releases. The exact version actually used is
      # recorded in the lock file written by `packer init`.
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

# "proxmox-iso" means: build from an installer ISO rather than from an existing
# cloud image. Everything in this block describes the temporary VM the install
# runs inside -- most of it is inherited by every clone Terraform later makes,
# so settings here are cluster-wide defaults, not just build-time choices.
source "proxmox-iso" "ubuntu-k8s" {
  proxmox_url = var.proxmox_url
  username    = var.proxmox_api_token_id
  token       = var.proxmox_api_token_secret
  node        = var.proxmox_node
  # Proxmox ships a self-signed TLS certificate by default, which would
  # otherwise be rejected. Fine on a trusted LAN; revisit if this ever runs
  # across an untrusted network.
  insecure_skip_tls_verify = true

  vm_id                = var.k8s_template_vm_id
  vm_name              = "k8s-ubuntu-${var.ubuntu_version}-golden"
  template_name        = "k8s-ubuntu-${var.ubuntu_version}-golden"
  template_description = "Kubernetes golden image for the on-premises cluster"
  # The QEMU guest agent lets Proxmox see inside the VM -- report IPs, shut down
  # cleanly. Terraform waits on it, and the package is installed by autoinstall.
  qemu_agent = true
  # "virtio" devices are paravirtualized: the guest knows it is a VM and skips
  # emulating real hardware, which is significantly faster.
  scsi_controller = "virtio-scsi-single"
  bios            = "seabios"
  os              = "l26" # Proxmox's identifier for a modern Linux guest.

  # Build-VM sizing only. This is generous to keep the install quick; cluster
  # node sizing is set independently by Terraform, so it does not follow from
  # these numbers.
  cores   = 4
  memory  = 16384
  sockets = 1
  # Passes the host CPU's real features through instead of a generic model.
  # Fastest option, but it ties the template to this CPU family -- live-
  # migrating to a host with a different CPU can fail.
  cpu_type = "host"

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
    # Clones inherit this from the template rather than setting their own, so it has to be a
    # setting that's safe for long-lived cluster nodes, not just the throwaway build VM.
    cache_mode = "none"
    discard    = true
    io_thread  = true
    ssd        = true
  }

  boot_iso {
    type    = "scsi"
    iso_url = var.ubuntu_iso_url
    # Verifies the download. "file:...SHA256SUMS" points at Ubuntu's published
    # checksum list so this does not need updating on every point release.
    iso_checksum = var.ubuntu_iso_checksum
    # Proxmox downloads the ISO itself, server-side, rather than pulling it
    # through the machine running Packer. Keep this true -- with it false,
    # Packer caches a multi-GB ISO locally (see .gitignore).
    iso_storage_pool = var.iso_datastore_id
    iso_download_pve = true
    # Eject the installer before templating, so clones don't boot back into it.
    unmount = true
  }

  # Packer starts a temporary web server on the build machine and serves these
  # two files. The Ubuntu installer fetches them and installs unattended --
  # this is what replaces a human clicking through the installer.
  # templatefile() substitutes the ${...} placeholders inside http/user-data,
  # which is how the SSH user and key get in without being committed here.
  http_content = {
    "/meta-data" = file("${path.root}/http/meta-data")
    "/user-data" = templatefile("${path.root}/http/user-data", {
      ssh_username      = var.ssh_username
      ssh_public_key    = var.ssh_public_key
      ssh_password_hash = var.ssh_password_hash
    })
  }

  boot_wait = "5s"

  # Keystrokes Packer types at the VM's console, since there is no other way to
  # talk to a machine that has no OS yet. This interrupts GRUB (<esc>, then "c"
  # for a command line) and boots the installer by hand with `autoinstall`
  # plus the address of the web server above.
  #
  # {{ .HTTPIP }}/{{ .HTTPPort }} are filled in by Packer at run time. The ";"
  # is escaped as "\\;" because GRUB would otherwise read it as a command
  # separator. <wait> pauses between keystrokes -- without them the input
  # outruns the console and the line arrives garbled.
  boot_command = [
    "<wait><wait><esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>",
  ]

  # How Packer connects once the install finishes, to run the provisioner.
  # The generous timeout covers the full unattended install, which is most of
  # the ~15 minute build.
  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "30m"
}

build {
  name    = "ubuntu-k8s"
  sources = ["source.proxmox-iso.ubuntu-k8s"]

  # Uploads scripts/provision-k8s.sh to the build VM and runs it as root. That
  # script does all the actual image customization; everything above only
  # describes the VM it runs inside.
  provisioner "shell" {
    script = "scripts/provision-k8s.sh"

    # {{ .Vars }} sets environment_vars in the shell, then sudo runs the script
    # as root. sudo normally scrubs the environment, so the variables reach the
    # script via the env_keep rule in http/user-data's sudoers drop-in. (Note
    # that `sudo -E` does NOT work here -- it is rejected by sudo's policy and
    # only prints a warning, which is why env_keep does the job instead.)
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -S bash '{{ .Path }}'"

    # Tolerate the SSH connection dropping mid-script instead of failing the
    # build. Nothing in the script currently reboots or restarts sshd, so this
    # is insurance rather than a requirement -- but a 15-minute build is an
    # expensive thing to lose to a transient disconnect.
    expect_disconnect = true

    environment_vars = [
      "KUBERNETES_REPO_VERSION=${var.kubernetes_repo_version}",
      "HOLD_KUBERNETES_PACKAGES=${var.hold_kubernetes_packages}",
    ]
  }
}
