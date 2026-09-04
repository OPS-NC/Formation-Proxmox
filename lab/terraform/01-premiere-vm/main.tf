resource "proxmox_virtual_environment_vm" "web" {
  name        = "web01"
  description = "Première VM Terraform — TP 11"
  node_name   = var.pve_node
  # Pas de vm_id : le provider demande le prochain VMID libre à Proxmox
  # (comme « pvesh get /cluster/nextid »). Rien à calculer, ni seul ni en cluster.
  pool_id = "lab"

  # ⭐ Ces tags pilotent l'inventaire Ansible du TP 13
  tags = ["terraform", "web", "dmz", "debian"]

  clone {
    vm_id = var.template_debian
    # linked clone : instantané et économe en disque.
    # 🪤 MAIS un linked clone sur stockage local N'EST PAS MIGRABLE entre nœuds
    #    (« can't migrate ... as it's a clone of ... »). C'est sans conséquence
    #    ici — cette VM ne quitte pas son nœud — mais les VM des TP 17 et 19
    #    doivent être des clones COMPLETS, ou vivre sur Ceph.
    full = false
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    # Pas « host » : on veut pouvoir migrer à chaud au jour 4
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge   = var.vnet
    model    = "virtio"
    mtu      = 1 # hérite du MTU du VNet — vital en EVPN
    firewall = true
  }

  initialization {
    # L'IPAM + dnsmasq du SDN s'occupent de l'adressage
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "eleve"
      keys     = [var.ssh_public_key]
    }
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}
