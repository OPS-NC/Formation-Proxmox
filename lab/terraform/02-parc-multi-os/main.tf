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

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
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

resource "proxmox_virtual_environment_container" "cache" {
  node_name = var.pve_node
  pool_id   = "lab"
  tags      = ["terraform", "cache", "dmz", "alpine"]

  description = "Conteneur Alpine déployé par Terraform — TP 11"

  initialization {
    hostname = "ct-cache"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name     = "eth0"
    bridge   = "vdmz"
    firewall = true
  }

  operating_system {
    template_file_id = var.lxc_template_alpine
    type             = "alpine"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 256
    swap      = 128
  }

  disk {
    datastore_id = "local-lvm"
    size         = 2
  }

  unprivileged  = true
  start_on_boot = true
}
