# How Terraform authenticates to Proxmox.
#
# A "provider" is the plugin that translates Terraform resources into API calls
# against a specific platform -- here, Proxmox VE.
provider "proxmox" {
  endpoint = var.proxmox_url

  # Proxmox expects the token as a single "user@realm!token-name=secret" string.
  # API tokens are preferable to a username and password: they can be scoped and
  # revoked without touching the account.
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"

  # Accept Proxmox's default self-signed TLS certificate. Reasonable on a
  # trusted LAN; revisit if this ever runs across an untrusted network.
  insecure = true
}
