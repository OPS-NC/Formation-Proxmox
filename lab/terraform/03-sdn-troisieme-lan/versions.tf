terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # ⚠ Les ressources SDN (vnet, subnet, applier) n'existent qu'à partir de
      #   la v0.84.0 du provider. « >= 0.80 » se résoudrait sur une version qui
      #   ne les connaît pas → « Invalid resource type ».
      #
      # 📌 On utilise les noms courts proxmox_sdn_* : la famille
      #    proxmox_virtual_environment_sdn_* est dépréciée (suppression en v1.0
      #    du provider) et fait crier « terraform validate ». Seul le SDN a été
      #    renommé ; les VM et conteneurs gardent proxmox_virtual_environment_*.
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
