output "controller_ip" {
  description = "IP address of the control-plane node."
  value       = var.controller_ip
}

output "worker_ips" {
  description = "IP addresses of the worker nodes."
  value       = local.worker_ips
}

output "fetch_kubeconfig_command" {
  description = "Run this locally to pull the cluster's kubeconfig off the control-plane node."
  value       = "scp -i ${var.ssh_private_key_file} ${var.ssh_username}@${var.controller_ip}:.kube/config ./kubeconfig"
}
