# Builds a Windows 11 "golden image": a Proxmox VM template with Brave, Blue
# Iris, and Tailscale preinstalled, ready to clone.
#
# The build is: create a throwaway VM -> boot the Windows installer -> answer
# every Setup prompt unattended (http/autounattend.xml, injected via a small
# generated CD Packer builds on the fly) -> Setup's specialize pass turns on
# WinRM (http/enable-winrm.ps1) -> Packer connects over WinRM and runs
# scripts/provision-apps.ps1 -> sysprep generalizes the disk -> shut down ->
# convert the VM into a template.
#
# This mirrors ../packer/ubuntu-k8s.pkr.hcl's shape (throwaway VM, unattended
# install, provisioner, template) but almost every mechanism underneath is
# different -- Windows has no cloud-init, no apt, and no SSH by default. See
# README.md for the full list of what's different and why.

packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

# --- Proxmox connection -----------------------------------------------------
# Same connection details as ../packer -- Packer and Terraform in this repo
# already share one .env, and Proxmox itself doesn't care which OS is being
# installed. See repo-root README.md's "Secrets" section.

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
  description = "Proxmox datastore for the image disk, EFI disk, and TPM state."
}

variable "iso_datastore_id" {
  type        = string
  description = "Proxmox datastore the boot ISO and VirtIO driver ISO are downloaded to."
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge."
}

# --- Windows install ---------------------------------------------------------

variable "windows_iso_file" {
  type        = string
  description = "Proxmox volume ID of an already-uploaded Windows 11 ISO, e.g. \"nvmePCI_dir:iso/Win11_25H2_English_x64_v2.iso\". Unlike Ubuntu's releases.ubuntu.com, Microsoft's download page is a session-gated flow with no stable URL to fetch programmatically -- upload the ISO to the datastore by hand (or via the Proxmox UI) once, and point this at it."
}

variable "windows_product_key" {
  type = string
  # This is Microsoft's own publicly documented generic "KMS client setup key"
  # for Windows 11 Pro -- it exists specifically so unattended installs can
  # select an edition without embedding a real license key. It does NOT
  # activate Windows; the installed image will show as unactivated until you
  # apply a real retail/volume key. None of Brave/Blue Iris/Tailscale need
  # activation to install, so this only matters for the Windows watermark.
  default     = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
  description = "Product key used to select the Windows edition during setup. Default is Microsoft's public Pro KMS client setup key (does not activate Windows)."
}

variable "computer_name" {
  type        = string
  default     = "win11-golden"
  description = "Placeholder hostname baked into the image. There is no cloud-init here to rename clones on first boot (see README.md) -- rename manually or extend the build before relying on this for more than one machine."
}

variable "timezone" {
  type        = string
  default     = "UTC"
  description = "Windows timezone ID (e.g. \"UTC\", \"Eastern Standard Time\") applied during specialize."
}

# --- WinRM (this build's equivalent of SSH) ----------------------------------

variable "winrm_username" {
  type        = string
  default     = "Administrator"
  description = "Local administrator account Packer connects as over WinRM."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password for winrm_username, supplied via PKR_VAR_winrm_password. Also becomes the account's real login password, so treat it like the ssh_password_hash in ../packer -- never commit it."
}

# --- VirtIO drivers -----------------------------------------------------------
# Windows has no built-in driver for the virtio-scsi controller used below, so
# Setup can't even see the disk without one. Fedora's virtio-win project builds
# a signed driver package for exactly this; http/drivers/vioscsi/ holds just
# the four files Setup needs (extracted once from
# https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso,
# vioscsi/w11/amd64/ inside it), embedded directly into the generated cidata
# CD below rather than attached as a separate ~770MB device -- see that
# block's comment for why a separate device doesn't work here. Re-extract
# from a newer virtio-win release the same way if you ever bump versions.

variable "windows_template_vm_id" {
  type        = number
  default     = 9005
  description = "VM ID assigned to the Windows 11 golden image. 9000 is already taken by ../packer's Kubernetes image."
}

# "proxmox-iso" again -- same builder as the Ubuntu image, but Windows 11's
# hardware requirements (UEFI, Secure Boot, TPM 2.0) mean most of the VM
# hardware settings below differ from ubuntu-k8s.pkr.hcl even though the block
# shape is identical.
source "proxmox-iso" "windows11" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_id                = var.windows_template_vm_id
  vm_name              = "windows11-golden"
  template_name        = "windows11-golden"
  template_description = "Windows 11 golden image: Brave, Blue Iris, Tailscale"
  qemu_agent           = true
  scsi_controller      = "virtio-scsi-single"

  # UEFI + Secure Boot + TPM 2.0 are non-negotiable for Windows 11 Setup --
  # skip any of the three and Setup refuses to install at all (short of a
  # registry-bypass hack in the answer file, which this build doesn't use).
  bios    = "ovmf"
  machine = "q35" # q35 is the chipset Proxmox's OVMF/TPM support targets; the older "pc" machine type doesn't reliably support both together.
  os      = "win11"

  # Explicit boot order restricted to just the Windows ISO and the OS disk.
  # Without this, OVMF's boot menu also considers the VirtIO driver ISO and
  # the generated cidata ISO as boot candidates (they're on the same IDE bus)
  # -- confirmed live via the Proxmox console that the firmware was landing on
  # "No bootable option or device was found" even with a spread-out
  # boot_command, which fits OVMF's own "press any key" prompt cycling across
  # multiple CD-ROM devices rather than waiting on the one that matters.
  boot = "order=ide0;scsi0"

  efi_config {
    efi_storage_pool = var.datastore_id
    efi_type         = "4m"
    # Pre-enrolls Microsoft's standard Secure Boot keys, so Secure Boot can be
    # ON (Setup checks for this) without you enrolling keys by hand.
    pre_enrolled_keys = true
  }

  tpm_config {
    tpm_storage_pool = var.datastore_id
    tpm_version      = "v2.0"
  }

  # Generous relative to the Linux build: Windows Setup plus first-boot
  # servicing is slower than an Ubuntu install, and this is build-VM sizing
  # only, same as ubuntu-k8s.pkr.hcl -- it doesn't constrain how clones of the
  # template get sized later.
  cores    = 8
  memory   = 16384
  sockets  = 1
  cpu_type = "host"

  # e1000 here is a deliberate simplification, not an oversight: it's a NIC
  # Windows recognizes natively, so networking works during Setup and first
  # boot with zero driver injection. The cost is a slightly slower emulated
  # NIC in every clone. If that ever matters, the fix is switching this to
  # "virtio" and adding NetKVM to the <PnPCustomizationsWinPE> driver paths in
  # http/autounattend.xml alongside vioscsi -- same technique, one more driver.
  network_adapters {
    model    = "e1000"
    bridge   = var.network_bridge
    firewall = true
  }

  disks {
    disk_size    = "80G" # Windows 11 + updates + three apps needs far more headroom than Ubuntu's 20G.
    storage_pool = var.datastore_id
    type         = "scsi"
    format       = "raw"
    cache_mode   = "none"
    discard      = true
    io_thread    = true
    ssd          = true
  }

  # The Windows installer ISO, already uploaded to the datastore (iso_file,
  # not iso_url -- see windows_iso_file's description for why). IDE rather
  # than the disk's virtio-scsi bus -- Setup's boot-time CD-ROM handling is
  # more predictable on IDE, and unlike the OS disk this device doesn't
  # survive into the template (unmount below).
  boot_iso {
    type     = "ide"
    iso_file = var.windows_iso_file
    unmount  = true
  }

  # One more virtual CD-ROM alongside the Windows ISO: a small ISO Packer
  # builds on the fly from http/*, containing autounattend.xml,
  # enable-winrm.ps1, and just the vioscsi driver files (not the full ~770MB
  # VirtIO ISO -- see below for why). Windows Setup auto-scans every attached
  # volume for autounattend.xml at boot -- unlike Ubuntu's autoinstall,
  # there's no boot_command URL to point it at.
  #
  # This used to be two separate devices (VirtIO ISO on its own, this one
  # generated by Packer), both type "ide". That combination -- three CD-ROMs
  # sharing one bus on this q35 machine ("ide" is actually AHCI/SATA here;
  # q35 has no legacy IDE controller) -- made OVMF crash-loop trying to load
  # Boot0002 before Setup's UI ever appeared, confirmed via continuous
  # screendumps (see /root/vm-snapshot-loop.sh on the Proxmox host) isolating
  # it to device count on that bus, not content. Moving this device to the
  # scsi bus instead "fixed" that, but broke something more fundamental:
  # Setup's very first scan for autounattend.xml happens before it has
  # processed anything *from* that file, including the <DriverPaths> that
  # would load vioscsi -- so anything living on the virtio-scsi controller is
  # invisible at exactly the moment Setup needs to find the answer file on
  # it. Confirmed live: boot succeeded, but Setup just sat at the language
  # selection screen forever, because it never found autounattend.xml at all.
  #
  # The actual fix is staying on the natively-visible ide/sata bus (WinPE has
  # a generic AHCI driver built in, no chicken-and-egg problem) while getting
  # back down to two devices total on it -- by not needing a separate VirtIO
  # ISO device in the first place. The other ~15 driver packages on that ISO
  # (NetKVM, balloon, qxl, ...) are irrelevant here anyway -- e1000 was
  # already chosen for networking specifically to avoid needing virtio
  # drivers for anything but storage. So: just the four vioscsi files, copied
  # out of the VirtIO ISO once (top-level vioscsi/, a sibling of http/, NOT
  # nested inside it -- cd_files preserves the path relative to path.root, so
  # a source of "http/vioscsi" lands at http/vioscsi/w11/amd64 inside the ISO
  # instead of the vioscsi/w11/amd64 autounattend.xml's <DriverPaths> actually
  # searches. That exact mismatch was caught live via a screendump loop: Setup
  # silently found no driver at D:/E:/F:\vioscsi\w11\amd64, couldn't see the
  # virtio-scsi disk, and crash-rebooted within seconds of reaching WinPE) and
  # embedded directly in this same generated CD, at the same relative path
  # autounattend.xml's <DriverPaths> already searches
  # (D:/E:/F:\vioscsi\w11\amd64) -- since it's now the same volume as
  # autounattend.xml itself, not a separate one.
  additional_iso_files {
    type             = "ide"
    index            = 1
    iso_storage_pool = var.iso_datastore_id
    # cd_content only handles text (it's a map of ISO-path to string
    # content); the driver files are binary, so they go in via cd_files
    # instead, which copies real files byte-for-byte and preserves
    # directory structure -- vioscsi/w11/amd64/*.{inf,sys,cat} on disk lands
    # at the identical vioscsi/w11/amd64/ path inside the ISO, the same one
    # autounattend.xml's <DriverPaths> searches.
    cd_files = ["${path.root}/vioscsi"]
    cd_content = {
      "autounattend.xml" = templatefile("${path.root}/http/autounattend.xml", {
        winrm_username      = var.winrm_username
        winrm_password      = var.winrm_password
        computer_name       = var.computer_name
        windows_product_key = var.windows_product_key
        timezone            = var.timezone
      })
      # No variables to substitute -- the account WinRM connects as is
      # already fully provisioned by autounattend.xml before this runs.
      "enable-winrm.ps1" = file("${path.root}/http/enable-winrm.ps1")
    }
    cd_label = "cidata"
    unmount  = true
  }

  # No boot_command here on purpose. Every official Windows ISO's own
  # bootloader (cdboot.efi) shows "Press any key to boot from CD or DVD..."
  # with a keypress window open for only a couple of seconds and no second
  # chance -- and on this host, POST time before that window even opens was
  # measured varying anywhere from ~2s to 50+s across otherwise-identical
  # boots, so no fixed boot_wait/boot_command timing can race it reliably.
  # Scripted keystrokes (single presses, spread-out presses, 80s of tight
  # 1s-interval presses) all missed it at least some of the time.
  #
  # The actual fix is upstream of Packer: windows_iso_file should point at an
  # ISO with cdboot.efi/efisys.bin swapped for the *_noprompt variants
  # Microsoft already ships alongside them on every install ISO, specifically
  # for unattended deployment -- see README.md's "Building the no-prompt ISO"
  # section for the one-time xorriso command. With that ISO, ide0 boots
  # straight into Setup with no prompt and nothing to race, so boot_wait only
  # needs to cover ordinary firmware POST.
  boot_wait = "5s"

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  # Windows Setup + first-boot servicing + all the OOBE passes take a while
  # before WinRM is even listening; this has to outlast that, not just the
  # provisioner's own runtime.
  winrm_timeout = "6h"
  # Same reasoning as insecure_skip_tls_verify above: WinRM here is HTTP, not
  # HTTPS, which is fine on a trusted build LAN and wrong anywhere else.
  winrm_insecure = true
}

build {
  name    = "windows11"
  sources = ["source.proxmox-iso.windows11"]

  # TEMPORARY bare-install proof-of-concept provisioner, swapped in to prove
  # the unattended install + WinRM handshake works before layering the real
  # (slow, more failure-prone) app provisioning back in. Restore
  # `script = "scripts/provision-apps.ps1"` once this passes.
  provisioner "powershell" {
    inline = [
      "Write-Output 'PACKER PROOF-OF-CONCEPT: unattended install + WinRM connected successfully.'",
      "hostname",
      "shutdown /s /t 5 /f"
    ]
  }
}
