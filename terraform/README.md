# Kubernetes cluster

Clones the Packer golden image (template 9000) into a control-plane node and N
workers, then runs `kubeadm` to form a cluster. Build the image first — see
[../packer/README.md](../packer/README.md).

## Usage

```sh
cd terraform
cp terraform.auto.tfvars.example terraform.auto.tfvars   # first time only
set -a; source ../.env; set +a                           # see repo-root README.md

terraform init      # download the Proxmox provider
terraform plan      # show what would change, without changing it
terraform apply
```

Run it under `tmux`. Always read the plan before approving an apply — it names
every resource that would be created or destroyed.

## What happens during an apply

```
controller ─────────────> join_command ──────> worker_join[0..2]
                              ^                       ^
worker[0..2] ─────────────────┴───────────────────────┘
   (clone in parallel)
```

1. All four VMs clone from the template and boot in parallel. cloud-init gives
   each one its hostname, static IP, and SSH key.
2. On the controller, `scripts/init-control-plane.sh.tpl` runs `kubeadm init`
   and installs Calico as the pod network.
3. `join_command` reads the resulting join command — a short-lived bootstrap
   token plus the cluster CA hash — back off the controller.
4. Each worker runs that join command.

Joining is a separate resource from the worker VM on purpose. A worker's
*existence* does not depend on the cluster; only its join does. Keeping them
separate lets all four VMs build while the control plane is still initializing,
instead of sitting idle.

## Provisioners only run once — use `-replace`

This is the single most surprising thing about this config.

Terraform provisioners run **only when a resource is first created**. Editing
`scripts/init-control-plane.sh.tpl`, or rebuilding the golden image, changes
nothing about nodes that already exist — and `terraform plan` will correctly
report no changes, because from Terraform's point of view nothing about the
resource *definition* changed.

To roll out a new image or new bootstrap scripts, recreate the nodes:

```sh
terraform apply \
  -replace='proxmox_virtual_environment_vm.controller' \
  -replace='proxmox_virtual_environment_vm.worker[0]' \
  -replace='proxmox_virtual_environment_vm.worker[1]' \
  -replace='proxmox_virtual_environment_vm.worker[2]'
```

This destroys and rebuilds all four nodes, which destroys the cluster with them.
That is fine for a lab and very much not fine for anything holding data.

## After it comes up

```sh
terraform output fetch_kubeconfig_command   # prints the scp command to run
kubectl --kubeconfig ./kubeconfig get nodes
```

All nodes should reach `Ready` once Calico has rolled out — typically a minute
or two. `NotReady` for longer than that usually means the pod network did not
install.

## Troubleshooting

Run these on the node itself (`ssh ubuntu@<node-ip>`):

```sh
cloud-init status --long        # did the node get its identity? expect DataSourceNoCloud
journalctl -u kubelet -f        # kubelet is the agent that runs pods
sudo crictl ps                  # containers, straight from containerd
sudo crictl pods                # pod sandboxes
```

`kubelet` crash-looping before `kubeadm init`/`join` has run is normal — it has
no cluster to talk to yet.

### All nodes NotReady, `calico-node` in `Init:CrashLoopBackOff`

Check the init container's logs:

```sh
kubectl logs -n kube-system <calico-node-pod> -c upgrade-ipam
```

If it says *"This program can only be run on AMD64 processors with v2
microarchitecture support"*, the VMs are running a CPU model older than
x86-64-v2. Calico v3.32+ ships v2-only binaries.

The provider defaults to `qemu64`, which is v1 — and that default silently
overrides whatever `cpu_type` the Packer template was built with. `var.cpu_type`
exists to prevent this and defaults to `host`. Verify what a node actually got:

```sh
grep -m1 'model name' /proc/cpuinfo    # "QEMU Virtual CPU" means the default
grep -w sse4_2 /proc/cpuinfo           # absent on qemu64
```

Fixing it is an in-place `terraform apply` (no rebuild), but the CPU model is a
QEMU launch parameter — the VM needs a full **stop and start**, not a guest
reboot, before it takes effect.

If a node comes up as `k8s-golden` on an unexpected DHCP address, cloud-init did
not run; see the unseal section in [../packer/README.md](../packer/README.md).

## Files

| File | Purpose |
| --- | --- |
| `main.tf` | the VMs and the bootstrap wiring |
| `variables.tf` | inputs and their documentation |
| `providers.tf` / `versions.tf` | provider config and version constraints |
| `outputs.tf` | values printed after an apply |
| `scripts/init-control-plane.sh.tpl` | runs on the controller (`.tpl` = Terraform fills in values) |
| `scripts/fetch-join-command.sh` | runs locally, reads the join command off the controller |

`terraform.tfstate` records what actually exists and is gitignored — it holds
real resource IDs and can contain sensitive values. It is also the only record
of your infrastructure, so do not delete it. A team would move this to a remote
backend so state is shared and locked rather than living on one machine.

`kubeadm-join-command.sh` is generated at apply time and gitignored: it carries
a live bootstrap token.
