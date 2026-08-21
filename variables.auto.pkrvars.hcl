proxmox_url          = "https://10.10.3.201:8006/api2/json"
proxmox_api_token_id = "terraform@pve!provider"
proxmox_node         = "pve2"
datastore_id         = "nvmePCI_ZFS"
network_bridge       = "vmbr0"

ubuntu_version       = "26.04"
ubuntu_iso_url       = "https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso"
ubuntu_iso_checksum  = "sha256:REPLACE_WITH_OFFICIAL_CHECKSUM"
ssh_username         = "jreboll"
ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDKqsOkIuMQg5NFsWXvVQo/XnUm8clMdtFjh+CLbgU7 jreboll@forge"
ssh_password_hash    = "REPLACE_WITH_CRYPT_PASSWORD_HASH"
ssh_private_key_file = "/absolute/path/to/matching/private/key"

k8s_template_vm_id       = 9000
kubernetes_repo_version  = "v1.35"
hold_kubernetes_packages = true
