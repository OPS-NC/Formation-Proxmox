resource "proxmox_virtual_environment_vm" "parc" {
  for_each = var.machines

  name        = each.key
  description = "Déployée par Terraform — TP 11"
  node_name   = var.pve_node
  # Pas de vm_id : Proxmox attribue le prochain libre à chaque machine.
  # Le VMID n'est donc pas prévisible — on retrouve une machine par son NOM
  # (« qm list »), ou dans « terraform output vmids ».
  pool_id = "lab"

  # ⭐ Le fil rouge : ces tags deviennent des groupes Ansible au TP 13
  tags = concat(["terraform"], each.value.tags)

  clone {
    vm_id = var.templates[each.value.template]
    # 🪤 linked clone = non migrable entre nœuds sur stockage local.
    #    Ces VM restent sur leur nœud jusqu'au TP 19, où on les déplacera
    #    d'abord sur Ceph (qm move-disk) avant toute migration.
    full = false
  }

  agent {
    enabled = true
  }

  # Console série : c'est ce que « qm terminal » et les cloud-images utilisent
  serial_device {}
  vga {
    type = "serial0"
  }

  cpu {
    cores = each.value.cores
    # Rocky 10 exige la base x86-64-v3 ; v2-AES pour le reste (migrable partout)
    type = each.value.template == "rocky" ? "x86-64-v3" : "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge   = each.value.vnet
    model    = "virtio"
    mtu      = 1
    firewall = true
  }

  initialization {
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
    ignore_changes = [initialization[0].user_account[0].password]
  }
}

