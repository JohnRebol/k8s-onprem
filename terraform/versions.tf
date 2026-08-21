terraform {
  # terraform_data (used in main.tf) needs 1.4+; 1.7 is a comfortable floor.
  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      # The community Proxmox provider. Terraform has no official one.
      source = "bpg/proxmox"
      # "~> 0.66" allows 0.66 and later 0.x patch/minor releases but not 1.0,
      # which could change resource schemas. The exact version in use is pinned
      # in .terraform.lock.hcl -- that file IS committed, so everyone and every
      # CI run resolves to the same provider build.
      version = "~> 0.66"
    }
  }
}
