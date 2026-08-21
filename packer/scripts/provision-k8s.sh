#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_REPO_VERSION="v1.35"

export DEBIAN_FRONTEND=noninteractive

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

install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 5 --retry-delay 5 \
  "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPO_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPO_VERSION}/deb/ /
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl

swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

install -d -m 0755 /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl enable qemu-guest-agent
systemctl enable systemd-timesyncd

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

cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/hostname
rm -f /etc/ssh/ssh_host_*

apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/*
