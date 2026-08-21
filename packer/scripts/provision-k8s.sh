#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_REPO_VERSION="v1.35"
# Fingerprint of the isv:kubernetes OBS Project key that signs every core:/stable:*
# repo on pkgs.k8s.io (same key for all versions; expires 2026-12-29).
KUBERNETES_APT_KEY_FINGERPRINT="DE15B14486CD377B9E876E1A234654DA9A296436"

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
  gpg

install -d -m 0755 /etc/apt/keyrings
# pkgs.k8s.io's CDN (CloudFront/S3) intermittently 403s Release.key regardless of
# version (see kubernetes/k8s.io#6188, cri-o#9341/#8505); pull the key by fingerprint
# from the keyserver network first, falling back to the CDN download if that fails.
gpg_keyring_tmp="$(mktemp)"
if gpg --no-default-keyring --keyring "${gpg_keyring_tmp}" \
    --keyserver keyserver.ubuntu.com --recv-keys "${KUBERNETES_APT_KEY_FINGERPRINT}"; then
  gpg --no-default-keyring --keyring "${gpg_keyring_tmp}" --export \
    --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${KUBERNETES_APT_KEY_FINGERPRINT}"
else
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
    "https://pkgs.k8s.io/core:/stable:${KUBERNETES_REPO_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
rm -f "${gpg_keyring_tmp}" "${gpg_keyring_tmp}~"
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
 deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:${KUBERNETES_REPO_VERSION}/deb/ /
EOF
sed -i 's/^ deb/deb/' /etc/apt/sources.list.d/kubernetes.list

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

containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl enable qemu-guest-agent
systemctl enable systemd-timesyncd

if [[ "${HOLD_KUBERNETES_PACKAGES}" == "true" ]]; then
  apt-mark hold kubelet kubeadm kubectl
fi

systemctl enable ssh

rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -rf /var/lib/cloud/*
truncate -s 0 /etc/hostname
rm -f /etc/ssh/ssh_host_*

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
