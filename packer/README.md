# Kubernetes golden image

Builds an Ubuntu Proxmox template with containerd and the Kubernetes packages
preinstalled. Terraform clones this template to create cluster nodes — see
[../terraform/README.md](../terraform/README.md).

Cluster-specific values (node IPs, sizing) deliberately live in the
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
packer validate -var-file=variables.auto.pkrvars.hcl \
  -var "packer_repo_git_sha=$(git rev-parse HEAD)" \
  -var "build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" .
./build.sh                                                # clean-tree check + stamped build
```

Run it under `tmux` — closing your SSH session otherwise kills the build.
Commit the Packer changes before running `build.sh`; it refuses a tracked dirty
worktree and stamps the clean commit SHA and UTC build time into the image.

`variables.auto.pkrvars.hcl` holds environment-specific, non-secret values
(which Proxmox node, which datastore). Connection details and keys come from
`.env` instead. Both are gitignored; only the `.example` is committed.

### Rebuilding an existing template

`packer build` refuses to overwrite an existing VM ID. To replace the template:

```sh
packer build -force -var-file=variables.auto.pkrvars.hcl .
```

This deletes template 9001 and rebuilds it. Template 9000 remains untouched as
the rollback image. Existing cluster nodes are full clones, so they keep running.
Terraform is switched to 9001 separately after a test clone passes.

## What the image contains

Installed and configured by `scripts/provision-k8s.sh`:

- **containerd 2.2.2-0ubuntu1.1**, held alongside the Kubernetes packages so
  unattended upgrades cannot restart the runtime or skew a node
- **kubelet, kubeadm, kubectl 1.36.5-1.1**, held for deliberate Kubernetes
  upgrades; other Ubuntu security updates remain enabled
- **crictl** for debugging containers directly against containerd, below
  Kubernetes — often the only thing that works when the control plane is down
- chrony as the only enabled time daemon; `systemd-timesyncd` is disabled and
  masked
- swap disabled, `overlay` + `br_netfilter` modules, Kubernetes networking
  sysctls, and inotify limits for monitoring and pod density
- cloud-init defaults to the `deploy` account with key-based SSH and
  passwordless sudo; the temporary `ubuntu` build account is locked and removed
  from SSH/sudo access during Packer's final shutdown command
- `/etc/golden-image-release` records Kubernetes, containerd, cri-tools, build
  timestamp, and source commit

The image does not install NFS packages; local-path-provisioner is installed
later in-cluster. Patching policy: Ubuntu security updates remain enabled, while
containerd and the three Kubernetes packages are held for manual updates.

The Proxmox NIC firewall is enabled on the template. Before rollout, verify the
effective datacenter, node, and VM firewall rules permit TCP 6443 inbound to the
control plane, TCP 10250 from the control plane to kubelets, and UDP 4789
bidirectionally between nodes for Calico VXLAN.
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
