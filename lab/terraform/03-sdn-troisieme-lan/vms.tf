# ⚠ depends_on est OBLIGATOIRE : sans lui, Terraform peut créer la VM avant que
#   le bridge « vsrv » n'existe réellement sur le nœud (la ressource SDN est
#   « créée » dès l'écriture du fichier de config, pas après l'apply).
#   Erreur typique : bridge 'vsrv' does not exist.

resource "proxmox_virtual_environment_vm" "mon" {
  depends_on = [proxmox_sdn_applier.apply, terraform_data.push_fw]


  name        = "mon01"
  description = "Supervision — zone services — TP 12"
  node_name   = var.pve_node
  pool_id     = "lab"
  tags        = ["terraform", "services", "monitoring", "debian"]

  clone {
    vm_id = var.template_debian
    # 🪤 linked clone = non migrable entre nœuds sur stockage local (cf. TP 10 §5).
    full = false
  }

  agent { enabled = true }

  # Console série : « qm terminal » et logs de boot des cloud-images
  serial_device {}
  vga { type = "serial0" }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge   = proxmox_sdn_vnet.srv.id
    model    = "virtio"
    mtu      = 1
    firewall = true
  }

  initialization {
    ip_config {
      ipv4 { address = "dhcp" }
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
