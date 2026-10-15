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

# Build inputs are passed in by Packer (environment_vars in
# ubuntu-k8s.pkr.hcl). Defaults keep the script runnable by hand for debugging.
KUBERNETES_REPO_VERSION="${KUBERNETES_REPO_VERSION:-v1.36}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.36.5}"
KUBERNETES_PACKAGE_VERSION="${KUBERNETES_PACKAGE_VERSION:-1.36.5-1.1}"
CONTAINERD_PACKAGE_VERSION="${CONTAINERD_PACKAGE_VERSION:-2.2.2-0ubuntu1.1}"
PACKER_REPO_GIT_SHA="${PACKER_REPO_GIT_SHA:-unknown}"
BUILD_DATE_UTC="${BUILD_DATE_UTC:-unknown}"

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
  "containerd=${CONTAINERD_PACKAGE_VERSION}" \
  socat \
  ebtables \
  ipset \
  iptables \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  chrony

# Add the Kubernetes apt repository. Ubuntu's own repos do not carry kubeadm.
#
# The key is fetched and stored on its own, then referenced by "signed-by" in
# the source line below. That scopes the key to this one repository, rather
# than trusting it to sign anything on the system.
#
# The URL is easy to get subtly wrong: the path needs a slash after "stable:"
# ("core:/stable:/v1.36/"). Without it the CDN answers 403 rather than 404, so
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
apt-get install -y \
  "kubelet=${KUBERNETES_PACKAGE_VERSION}" \
  "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
  "kubectl=${KUBERNETES_PACKAGE_VERSION}" \
  cri-tools

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
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
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
sed -ri 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml

if ! grep -Eq '^[[:space:]]*SystemdCgroup = true$' /etc/containerd/config.toml; then
  echo "containerd config is missing SystemdCgroup = true" >&2
  exit 1
fi
if ! grep -Fq 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
  echo "containerd registry config_path was not set" >&2
  exit 1
fi

KUBEADM_PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "${KUBERNETES_VERSION}" | awk '/pause:/ { print; count++ } END { if (count != 1) exit 1 }')"
sed -ri "s|^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$|\\1\"${KUBEADM_PAUSE_IMAGE}\"|" /etc/containerd/config.toml
CONTAINERD_PAUSE_IMAGE="$(sed -nE 's/^[[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' /etc/containerd/config.toml)"
if [[ "${CONTAINERD_PAUSE_IMAGE}" != "${KUBEADM_PAUSE_IMAGE}" ]]; then
  echo "containerd sandbox image ${CONTAINERD_PAUSE_IMAGE} does not match kubeadm image ${KUBEADM_PAUSE_IMAGE}" >&2
  exit 1
fi

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
# Kubernetes certificates and etcd leader election are time-sensitive. Keep one
# NTP client enabled so there is no competition over clock discipline.
systemctl disable --now systemd-timesyncd
systemctl mask systemd-timesyncd
systemctl enable --now chrony

# Hold the runtime and Kubernetes components. Ubuntu security updates remain
# enabled for other packages; these four packages are updated deliberately.
apt-mark hold containerd kubelet kubeadm kubectl

if [[ "${PACKER_REPO_GIT_SHA}" == "unknown" || "${BUILD_DATE_UTC}" == "unknown" ]]; then
  echo "Build stamp inputs must be supplied by packer/build.sh" >&2
  exit 1
fi
if [[ ! "${PACKER_REPO_GIT_SHA}" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "Packer repo git SHA is invalid" >&2
  exit 1
fi
if ! date -u -d "${BUILD_DATE_UTC}" >/dev/null; then
  echo "Build date must be a valid UTC timestamp" >&2
  exit 1
fi
CONTAINERD_VERSION="$(dpkg-query -W -f='${Version}' containerd)"
CRI_TOOLS_VERSION="$(dpkg-query -W -f='${Version}' cri-tools)"
cat >/etc/golden-image-release <<EOF
Kubernetes version: ${KUBERNETES_VERSION}
Kubernetes package version: ${KUBERNETES_PACKAGE_VERSION}
containerd version: ${CONTAINERD_VERSION}
cri-tools version: ${CRI_TOOLS_VERSION}
Build date UTC: ${BUILD_DATE_UTC}
Packer repo git SHA: ${PACKER_REPO_GIT_SHA}
EOF

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
cat >/etc/cloud/cloud.cfg.d/99-default-user.cfg <<'EOF'
system_info:
  default_user:
    name: deploy
    lock_passwd: true
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: []
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

passwd -l ubuntu
chage -E 0 ubuntu
rm -f /home/ubuntu/.ssh/authorized_keys /etc/sudoers.d/90-ubuntu
