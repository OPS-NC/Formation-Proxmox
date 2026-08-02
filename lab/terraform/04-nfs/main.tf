locals {
  template_id = coalesce(var.template_debian, var.eleve * 100 + 90)
}

resource "proxmox_virtual_environment_vm" "nfs" {
  name        = "nfs-lab"
  description = "Serveur NFS du lab — géré par Terraform (TP 14)"
  node_name   = var.pve_node
  vm_id       = 900 # hors des plages élèves
  pool_id     = "eleve${var.eleve}"

  # ⭐ Le tag « nfs » déclenche le rôle Ansible du même nom (TP 13)
  tags = ["terraform", "nfs", "storage", "infra", "debian"]

  clone {
    vm_id = local.template_id
    # full = true : un serveur de stockage ne doit dépendre d'aucun template
    full = true
  }

  agent { enabled = true }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  # Le disque de données, séparé du système → /dev/sdb dans l'invité
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = var.data_disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # ⚠ vmbr0 et NON un VNet SDN : le stockage doit être joignable par la pile
  #   réseau HÔTE des six nœuds. Un VNet SDN est réservé aux guests, et le
  #   mettre derrière du SNAT serait une très mauvaise idée.
  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.nfs_ip
        gateway = var.nfs_gateway
      }
    }

    dns {
      servers = [var.nfs_gateway]
      domain  = "lab.local"
    }

    user_account {
      username = "eleve"
      keys     = [var.ssh_public_key]
    }
  }

  # 🛟 Un « terraform destroy » distrait effacerait les disques de toute la salle.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_account[0].password]
  }
}
