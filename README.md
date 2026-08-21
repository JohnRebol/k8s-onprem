# k8s-onprem

## Secrets

Packer and Terraform share the same Proxmox connection and API token. Set them once in a repo-root `.env` file (gitignored, values single-quoted since some contain `$` or spaces):

```sh
PKR_VAR_proxmox_url='...'
TF_VAR_proxmox_url='...'
PKR_VAR_proxmox_api_token_id='...'
TF_VAR_proxmox_api_token_id='...'
PKR_VAR_proxmox_api_token_secret='...'
TF_VAR_proxmox_api_token_secret='...'
PKR_VAR_ssh_public_key='...'
PKR_VAR_ssh_password_hash='...'
PKR_VAR_ssh_private_key_file='/absolute/path/to/matching/private/key'
```

Load it before running either tool:

```sh
set -a; source .env; set +a
```

See [packer/README.md](packer/README.md) for the full Packer build flow.
