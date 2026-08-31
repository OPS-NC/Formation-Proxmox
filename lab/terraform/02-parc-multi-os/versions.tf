terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # ⚠ Les ressources SDN (vnet, subnet, applier) n'existent qu'à partir de
      #   la v0.84.0 du provider. « >= 0.80 » se résoudrait sur une version qui
      #   ne les connaît pas → « Invalid resource type » au TP 12.
      version = "~> 0.111"
    }
  }
}
