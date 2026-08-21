# Kubernetes golden image

This build creates an Ubuntu Proxmox template with containerd and the Kubernetes packages installed. The controller and worker VM IDs, addresses, gateway, DNS, and VM sizing in `.variables_to_set.txt` belong to the later Terraform cluster deployment and are intentionally not baked into the reusable image.

## Usage

1. Copy `variables.auto.pkrvars.hcl.example` to a local `.auto.pkrvars.hcl` file, set the official Ubuntu ISO checksum and private-key path, and provide a locally generated `crypt(3)` value for `ssh_password_hash`.
2. Export the Proxmox token secret without writing it to the repository:

```sh
export PKR_VAR_proxmox_api_token_secret='...'
```

3. Initialize, format, validate, and build:

```sh
packer init .
packer fmt -check .
packer validate -var-file=variables.auto.pkrvars.hcl .
packer build -var-file=variables.auto.pkrvars.hcl .
```

The local variable file and all `*.pkrvars.hcl` files are ignored by Git. Do not place the token secret in HCL, shell history, or command-line arguments.
