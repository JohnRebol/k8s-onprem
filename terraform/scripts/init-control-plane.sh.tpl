#!/usr/bin/env bash
# Runs on the control-plane node after it boots from the golden image.
#
# There is deliberately no equivalent of the old bootstrap-common.sh here: the
# Packer image already provides containerd (CRI enabled, systemd cgroups),
# kubelet/kubeadm/kubectl on hold, swap disabled, and the required kernel
# modules and sysctls. This script only does cluster initialization.
set -euo pipefail

# Terraform's SSH connection succeeds as soon as sshd accepts, which can be
# before cloud-init has applied the node's final hostname. kubeadm bakes the
# hostname into the cluster's certificates and node registration, so waiting
# here keeps the cluster from being built around the template's identity.
cloud-init status --wait >/dev/null 2>&1 || true

if [ -f /etc/kubernetes/admin.conf ]; then
  echo "control plane already initialized, skipping kubeadm init"
else
  kubeadm init \
    --apiserver-advertise-address="${control_plane_ip}" \
    --pod-network-cidr="${pod_network_cidr}"
fi

# Give the login user a working kubectl without needing sudo.
install -d -m 0700 -o ${username} -g ${username} /home/${username}/.kube
install -m 0600 -o ${username} -g ${username} \
  /etc/kubernetes/admin.conf /home/${username}/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"

# Hand the join command to Terraform so it can be relayed to the workers.
# Written to a token-bearing file, so keep it owner-only.
kubeadm token create --print-join-command > /tmp/kubeadm-join-command.sh
chmod 0600 /tmp/kubeadm-join-command.sh
