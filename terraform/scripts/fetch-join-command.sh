#!/usr/bin/env bash
# Fetches the kubeadm join command from the control-plane node so Terraform can
# relay it to the workers. Run locally by terraform_data.join_command's
# local-exec provisioner (main.tf) -- never uploaded to a VM.
#
# The old version of this script hopped through the Proxmox host as a bastion,
# because terraform ran somewhere that couldn't reach the 10.10.x.x node IPs.
# This repo runs terraform on a host with direct reachability, so it connects
# straight to the node.
set -euo pipefail

node_user="$1"
node_ip="$2"
key_path="$3"
out_file="$4"

key=$(mktemp)
tmp_out=$(mktemp)
trap 'rm -f "$key" "$tmp_out"' EXIT

# ssh refuses keys that are group/world readable, and the source copy may not
# be strict enough. Copy to a private temp file rather than chmod-ing the
# user's real key out from under them.
cp "$key_path" "$key"
chmod 600 "$key"

# Nodes are recreated with fresh host keys on every replace, so a pinned
# known_hosts entry would fail the connection rather than the deploy being
# wrong. Discard host key state instead of tracking it for throwaway lab nodes.
ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 \
  -i "$key" \
  "$node_user@$node_ip" \
  'sudo cat /tmp/kubeadm-join-command.sh' >"$tmp_out"

# Only overwrite the real file once the fetch succeeded, so a failed run leaves
# the previous join command intact instead of truncating it to nothing.
if [ ! -s "$tmp_out" ]; then
  echo "fetch-join-command: got an empty join command from $node_ip" >&2
  exit 1
fi

install -m 0600 "$tmp_out" "$out_file"
