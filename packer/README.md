# Kubernetes golden image

This build creates an Ubuntu Proxmox template with containerd and the Kubernetes packages installed. The controller and worker VM IDs, addresses, gateway, DNS, and VM sizing in `.variables_to_set.txt` belong to the later Terraform cluster deployment and are intentionally not baked into the reusable image.

## Usage

1. Copy `variables.auto.pkrvars.hcl.example` to a local `.auto.pkrvars.hcl` file.
2. Set the Proxmox connection details and SSH credentials in the repo-root `.env` file (gitignored — quote values containing `$` or spaces, e.g. `ssh_password_hash`, a locally generated `crypt(3)` hash) and load it into your shell:

```sh
# .env (repo root)
PKR_VAR_proxmox_url='...'
TF_VAR_proxmox_url='...'                        # same Proxmox host, used by the Terraform cluster deployment
PKR_VAR_proxmox_api_token_id='...'
TF_VAR_proxmox_api_token_id='...'
PKR_VAR_proxmox_api_token_secret='...'
TF_VAR_proxmox_api_token_secret='...'
PKR_VAR_ssh_public_key='...'
PKR_VAR_ssh_password_hash='...'
PKR_VAR_ssh_private_key_file='/absolute/path/to/matching/private/key'

set -a; source ../.env; set +a
```

3. Initialize, format, validate, and build:

```sh
packer init .
packer fmt -check .
packer validate -var-file=variables.auto.pkrvars.hcl .
packer build -var-file=variables.auto.pkrvars.hcl .
```

The local variable file and all `*.pkrvars.hcl` files are ignored by Git. Do not place the token secret in HCL, shell history, or command-line arguments.
