terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Ajustez si votre version installée est différente :
      #   terraform providers
      version = ">= 0.80"
    }
  }
}
