#!/usr/bin/env bash
# Provisions the Kubernetes golden image. Packer uploads this to the temporary
# build VM and runs it as root; the VM is then converted into a Proxmox
# template that Terraform clones to create cluster nodes.
#
# set -e   exit on the first failing command, so a broken build fails loudly at
#          the point of failure rather than producing a half-built image
# set -u   treat unset variables as errors, which catches typo'd names
# set -o pipefail  make a pipeline fail if any stage fails, not just the last
set -euo pipefail

# Both values are passed in by Packer (environment_vars in ubuntu-k8s.pkr.hcl).
# The ":-" fallbacks keep the script runnable by hand for debugging, and stop
# `set -u` from aborting if a variable didn't survive the sudo boundary.
KUBERNETES_REPO_VERSION="${KUBERNETES_REPO_VERSION:-v1.35}"
HOLD_KUBERNETES_PACKAGES="${HOLD_KUBERNETES_PACKAGES:-true}"

# Stop apt from trying to open interactive prompts; there is no terminal here.
export DEBIAN_FRONTEND=noninteractive

# Base packages. conntrack/socat/ebtables/ipset/iptables are what kube-proxy and
# kubelet shell out to for service networking and port-forwarding; kubeadm's
# preflight checks fail without them.
apt-get update
apt-get install -y \
  qemu-guest-agent \
  openssh-server \
  conntrack \
  containerd \
  socat \
  ebtables \
  ipset \
  iptables \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  systemd-timesyncd

# Add the Kubernetes apt repository. Ubuntu's own repos do not carry kubeadm.
#
# The key is fetched and stored on its own, then referenced by "signed-by" in
# the source line below. That scopes the key to this one repository, rather
# than trusting it to sign anything on the system.
#
# The URL is easy to get subtly wrong: the path needs a slash after "stable:"
# ("core:/stable:/v1.35/"). Without it the CDN answers 403 rather than 404, so
# it reads like an outage or a rate limit instead of a typo.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 5 --retry-delay 5 \
  "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPO_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPO_VERSION}/deb/ /
EOF

apt-get update
# cri-tools (crictl) comes from the Kubernetes repo rather than Ubuntu's so it
# tracks the cluster version. It talks to containerd below Kubernetes, which is
# often the only way to see what a node is doing when the control plane itself
# is the thing that's broken.
apt-get install -y kubelet kubeadm kubectl cri-tools

# Kubernetes requires swap to be off: the scheduler reasons about a node's real
# memory, and swap lets a node quietly exceed it instead of reporting pressure.
# swapoff handles the running system; the fstab edit stops it returning on boot.
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# overlay      the filesystem containers are layered with
# br_netfilter makes bridged traffic visible to iptables, which is how pod
#              networking and Service rules are enforced
# The modules-load.d file loads them on every boot; modprobe loads them now, so
# the sysctls below can be applied without a reboot.
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ip_forward lets the node route between pods; the bridge-nf settings make
# br_netfilter actually apply iptables to bridged traffic. Without these, pods
# come up but cannot talk to each other or to Services.
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# containerd is the container runtime -- the thing that actually starts
# containers when kubelet asks. Ubuntu's package ships no config file, so
# generate the default and switch the cgroup driver to systemd: kubelet uses
# systemd, and if the two disagree the node becomes unstable under memory
# pressure. ("cgroups" are the kernel feature that limits CPU/memory per
# container; both sides must agree on who manages them.)
install -d -m 0755 /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# Point crictl at containerd. Without this it has to guess an endpoint on every
# invocation, which it warns about and which breaks once more than one runtime
# socket exists on the node.
cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
systemctl enable qemu-guest-agent
# Kubernetes certificates and etcd leader election are time-sensitive; a node
# with a drifting clock fails to authenticate in confusing ways.
systemctl enable systemd-timesyncd

# "hold" pins these at the installed version so an unattended apt upgrade cannot
# move a node to a new Kubernetes minor on its own. Kubernetes upgrades have a
# required order (control plane before workers, one minor at a time), so they
# should be deliberate rather than incidental.
if [[ "${HOLD_KUBERNETES_PACKAGES}" == "true" ]]; then
  apt-mark hold kubelet kubeadm kubectl
fi

systemctl enable ssh

# Ubuntu's live installer seals the machine against cloud-init once autoinstall
# finishes, so the installed system won't re-run it like a fresh cloud instance.
# Those artifacts survive into the template and stop every clone from reading the
# cloud-init drive Proxmox attaches (datasource_list is pinned to None, and
# networking is disabled outright), leaving nodes on DHCP with the template's
# hostname. Unseal the image so clones pick up their per-VM config.
rm -f /etc/cloud/cloud-init.disabled
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg
rm -f /etc/cloud/cloud.cfg.d/*subiquity-disable-cloudinit-networking.cfg
cat >/etc/cloud/cloud.cfg.d/99-pve.cfg <<EOF
datasource_list: [ NoCloud, ConfigDrive ]
EOF

# Strip this machine's identity so clones do not all share one. Anything unique
# left in the image is inherited by every node built from it.
#
#   cloud-init clean  discards cached state, so clones re-run cloud-init from
#                     scratch instead of assuming they are already configured.
#                     --machine-id resets /etc/machine-id, which DHCP and
#                     systemd use to identify a host -- duplicates cause nodes
#                     to fight over the same DHCP lease.
#   hostname/ssh keys blanked so each clone generates its own on first boot;
#                     shared SSH host keys would make the nodes impersonable.
cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/hostname
rm -f /etc/ssh/ssh_host_*

# Shrink the image. Do NOT add /tmp/* here: Packer is running this script from
# /tmp, so deleting it removes the script mid-execution and the build fails
# with no useful error.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/*
