terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # ⚠ Les ressources SDN (vnet, subnet, applier) n'existent qu'à partir de
      #   la v0.84.0 du provider. « >= 0.80 » se résoudrait sur une version qui
      #   ne les connaît pas → « Invalid resource type ».
      #
      # 📌 La famille proxmox_virtual_environment_sdn_* est dépréciée au profit
      #    de proxmox_sdn_* (suppression annoncée en v1.0). Même schéma, nom
      #    plus court : la migration sera un simple renommage.
      version = "~> 0.111"
    }

    # Utilisé par firewall.tf pour générer le fichier .fw avant de le pousser.
    # Terraform sait le déduire tout seul, mais on déclare : c'est explicite,
    # et ça évite qu'une future version majeure surprenne.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
