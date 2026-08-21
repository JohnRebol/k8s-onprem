# Kubernetes golden image

Builds an Ubuntu Proxmox template with containerd and the Kubernetes packages
preinstalled. Terraform clones this template to create cluster nodes — see
[../terraform/README.md](../terraform/README.md).

Cluster-specific values (node IPs, VM IDs, sizing) deliberately live in the
Terraform config, not here. The image is meant to be reusable: nothing inside it
should know which node it will become.

## How the build works

1. Packer creates a temporary VM on Proxmox and attaches the Ubuntu ISO.
2. It serves `http/user-data` over a temporary local web server, and types a
   boot command at the VM's console telling the installer to fetch it. That file
   answers every installer prompt, so the install runs unattended.
3. Once the install finishes and SSH comes up, Packer uploads and runs
   `scripts/provision-k8s.sh`, which does the real customization.
4. The VM is shut down and converted into a template.

Most of the ~15 minute runtime is step 2.

## Usage

```sh
cd packer
cp variables.auto.pkrvars.hcl.example variables.auto.pkrvars.hcl   # first time only
set -a; source ../.env; set +a                                     # see repo-root README.md

packer init .                                              # download the Proxmox plugin
packer fmt -check .                                        # formatting
packer validate -var-file=variables.auto.pkrvars.hcl .     # config errors, without building
packer build -var-file=variables.auto.pkrvars.hcl .
```

Run it under `tmux` — closing your SSH session otherwise kills the build.

`variables.auto.pkrvars.hcl` holds environment-specific, non-secret values
(which Proxmox node, which datastore). Connection details and keys come from
`.env` instead. Both are gitignored; only the `.example` is committed.

### Rebuilding an existing template

`packer build` refuses to overwrite an existing VM ID. To replace the template:

```sh
packer build -force -var-file=variables.auto.pkrvars.hcl .
```

This deletes template 9000 and rebuilds it. Existing cluster nodes are full
clones, so they keep running — but they still contain the *old* image until
Terraform recreates them.

## What the image contains

Installed and configured by `scripts/provision-k8s.sh`:

- **containerd** as the container runtime, with systemd cgroups (Kubernetes
  requires the runtime and kubelet to agree on the cgroup driver)
- **kubelet, kubeadm, kubectl**, held at their installed version so an
  unattended `apt upgrade` cannot skew the cluster mid-life
- **crictl** for debugging containers directly against containerd, below
  Kubernetes — often the only thing that works when the control plane is down
- swap disabled, `overlay` + `br_netfilter` modules, and the sysctls Kubernetes
  networking needs
- **cloud-init unsealed** — see below

### The cloud-init unseal

Ubuntu's installer disables cloud-init once autoinstall finishes, so the
installed machine will not re-run it. That is correct for a normal install and
wrong for a golden image: the artifacts survive into the template, and every
clone then ignores the configuration Proxmox hands it, coming up on DHCP with
the template's hostname and no SSH key.

`provision-k8s.sh` removes those artifacts and pins the datasource list back to
`[NoCloud, ConfigDrive]`. If cluster nodes ever come up as `k8s-golden` on a
DHCP address, this is the first thing to check:

```sh
cloud-init status --long          # expect: DataSourceNoCloud [seed=/dev/sr0]
ls /etc/cloud/cloud-init.disabled # expect: not found
```
