# Inputs to this configuration. Values come from two places:
#
#   - terraform.auto.tfvars   environment-specific but not secret (node names,
#                             IPs, sizing). Auto-loaded; gitignored.
#   - TF_VAR_* env vars       connection details and keys, from the repo-root
#                             .env file. See README.md.
#
# A variable with no default is required: Terraform will refuse to run without
# it rather than guessing.

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, supplied via TF_VAR_proxmox_url."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID, supplied via TF_VAR_proxmox_api_token_id."
}

variable "proxmox_api_token_secret" {
  type        = string
  sensitive   = true
  description = "Proxmox API token secret, supplied via TF_VAR_proxmox_api_token_secret."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node the cluster VMs are created on."
}

variable "datastore_id" {
  type        = string
  description = "Proxmox datastore for cloned VM disks."
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge."
}

variable "k8s_template_vm_id" {
  type        = number
  description = "VM ID of the Kubernetes golden image template built by Packer."
}

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "Cloud-init user created on cluster nodes."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key installed for ssh_username via cloud-init."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the private key matching ssh_public_key, used by the bootstrap provisioners. Supplied via TF_VAR_ssh_private_key_file."
}

variable "cpu_type" {
  type        = string
  default     = "host"
  description = <<-EOT
    QEMU CPU model for cluster nodes.

    This must be set explicitly: the provider defaults to "qemu64", a baseline
    model that lacks SSE4.2/POPCNT and therefore does not meet the x86-64-v2
    microarchitecture level. Calico v3.32+ ships v2-only binaries and its
    calico-node pods crash-loop on a qemu64 node, leaving every node NotReady.
    A cpu_type set on the Packer template does NOT carry over -- the value here
    overrides it.

    "host" passes the physical CPU's features straight through and is the
    fastest option. The tradeoff is portability: it ties these VMs to this CPU
    family, so live-migrating to a host with a different CPU can fail. On a
    mixed-CPU cluster, use a named baseline that is still v2 or better
    (e.g. "x86-64-v2-AES") instead.
  EOT
}

variable "pod_network_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "Pod network CIDR passed to kubeadm init. The default matches Calico's own default and must not overlap the node network."
}

variable "calico_version" {
  type        = string
  default     = "v3.32.1"
  description = "Calico release whose manifest is applied as the cluster CNI."
}

variable "controller_vm_id" {
  type        = number
  description = "VM ID for the control-plane node."
}

variable "controller_ip" {
  type        = string
  description = "Static IP address for the control-plane node."
}

variable "controller_cores" {
  type        = number
  description = "vCPU cores for the control-plane node."
}

variable "controller_memory" {
  type        = number
  description = "Memory (MB) for the control-plane node."
}

variable "worker_vm_id_start" {
  type        = number
  description = "VM ID assigned to the first worker node; subsequent workers increment from here."
}

variable "worker_ip_start" {
  type        = string
  description = "Static IP assigned to the first worker node; subsequent workers increment the last octet from here."
}

variable "worker_count" {
  type        = number
  description = "Number of worker nodes to create."
}

variable "worker_cores" {
  type        = number
  description = "vCPU cores per worker node."
}

variable "worker_memory" {
  type        = number
  description = "Memory (MB) per worker node."
}

variable "network_gateway" {
  type        = string
  description = "Default gateway for cluster node network config."
}

variable "network_cidr_suffix" {
  type        = number
  description = "CIDR prefix length applied to controller_ip and worker IPs."
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers for cluster node network config."
}
