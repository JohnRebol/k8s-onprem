# k8s-onprem

Builds a Kubernetes cluster on an on-premises Proxmox host, in two stages:

| Stage | Tool | What it does | Runs from |
| --- | --- | --- | --- |
| 1. Golden image | Packer | Installs Ubuntu + containerd + Kubernetes tooling once, saves it as a reusable Proxmox **template** (VM 9000) | `packer/` |
| 2. Cluster | Terraform | Clones that template into a control-plane node and N workers, then runs `kubeadm` to form the cluster | `terraform/` |

Stage 1 is slow (~15 minutes) and runs rarely. Stage 2 is fast and runs whenever
the cluster is rebuilt. Splitting them is the point: every node boots from a
byte-identical image, so nodes cannot drift apart, and creating one does not
mean waiting for package downloads.

## New to this stack?

- **Proxmox** is the hypervisor — the machine that runs the VMs.
- **A template** is a VM frozen as a golden master. Cloning it is near-instant
  compared to installing an OS.
- **Packer** builds images. **Terraform** creates infrastructure from them and
  records what exists in a state file, so it can compute the difference between
  what you asked for and what is running.
- **cloud-init** is what turns one identical template into differently
  configured nodes — on first boot each VM reads its own hostname, IP, and SSH
  key from a small virtual CD-ROM that Proxmox attaches.
- **kubeadm** turns configured machines into a Kubernetes cluster: `kubeadm
  init` on the control plane, `kubeadm join` on each worker.

## Secrets

Packer and Terraform share the same Proxmox connection and API token. Set them
once in a repo-root `.env` file (gitignored). Both tools read configuration from
environment variables with a tool-specific prefix — `PKR_VAR_x` sets Packer's
variable `x`, `TF_VAR_x` sets Terraform's — which is why most values appear
twice.

Quote values single-quoted; some contain `$` or spaces.

```sh
PKR_VAR_proxmox_url='...'
TF_VAR_proxmox_url='...'
PKR_VAR_proxmox_api_token_id='...'
TF_VAR_proxmox_api_token_id='...'
PKR_VAR_proxmox_api_token_secret='...'
TF_VAR_proxmox_api_token_secret='...'
PKR_VAR_ssh_public_key='...'
PKR_VAR_ssh_password_hash='...'                 # crypt(3) hash; autoinstall requires one
PKR_VAR_ssh_private_key_file='/absolute/path/to/matching/private/key'
TF_VAR_ssh_public_key='...'
TF_VAR_ssh_private_key_file='/absolute/path/to/matching/private/key'
```

Load it into your shell before running either tool:

```sh
set -a; source .env; set +a
```

`set -a` marks everything defined afterwards for export, so the variables reach
child processes; `set +a` turns that back off. Without it, `source` would define
the variables only in your own shell and Packer/Terraform would not see them.

Never put the token secret in HCL, shell history, or command-line arguments.

## 1. Build the golden image

```sh
cd packer
set -a; source ../.env; set +a
packer init .
packer validate -var-file=variables.auto.pkrvars.hcl .
packer build -var-file=variables.auto.pkrvars.hcl .
```

Add `-force` to replace an existing template with the same VM ID. Takes roughly
15 minutes — run it under `tmux` so a dropped SSH session does not kill it.

See [packer/README.md](packer/README.md) for details.

## 2. Deploy the cluster

```sh
cd terraform
set -a; source ../.env; set +a
terraform init
terraform plan
terraform apply
```

See [terraform/README.md](terraform/README.md) — in particular the note about
`-replace`, which you need whenever the image or the bootstrap scripts change.

## Layout

```
packer/
  ubuntu-k8s.pkr.hcl     build definition: the VM, the installer, the provisioner
  http/user-data         Ubuntu autoinstall answers (unattended install)
  scripts/               what runs inside the image during the build
terraform/
  main.tf                the VMs and the cluster bootstrap
  variables.tf           inputs
  scripts/               what runs on the nodes after they boot
```

Both directories have a `*.example` variables file. Copy it, fill in your own
values, and keep the copy out of Git — the real ones are gitignored because they
hold environment-specific addresses.
