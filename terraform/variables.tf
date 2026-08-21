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
