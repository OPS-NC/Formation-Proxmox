# ⚠ depends_on est OBLIGATOIRE : sans lui, Terraform peut créer la VM avant que
#   le bridge « vsrv » n'existe réellement sur le nœud (la ressource SDN est
#   « créée » dès l'écriture du fichier de config, pas après l'apply).
#   Erreur typique : bridge 'vsrv' does not exist.

resource "proxmox_virtual_environment_vm" "mon" {
  depends_on = [terraform_data.sdn_apply]

  name        = "mon01-e${var.eleve}"
  description = "Supervision — zone services — TP 12"
  node_name   = var.pve_node
  vm_id       = var.eleve * 100 + 50
  pool_id     = "eleve${var.eleve}"
  tags        = ["terraform", "services", "monitoring", "debian", "eleve${var.eleve}"]

  clone {
    vm_id = local.template_id
    full  = false
  }

  agent { enabled = true }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge   = proxmox_virtual_environment_sdn_vnet.srv.id
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

resource "proxmox_virtual_environment_container" "log" {
  depends_on = [terraform_data.sdn_apply]

  node_name   = var.pve_node
  vm_id       = var.eleve * 100 + 51
  pool_id     = "eleve${var.eleve}"
  tags        = ["terraform", "services", "logs", "alpine", "eleve${var.eleve}"]
  description = "Collecteur de journaux — TP 12"

  initialization {
    hostname = "log01-e${var.eleve}"
    ip_config {
      ipv4 { address = "dhcp" }
    }
    user_account { keys = [var.ssh_public_key] }
  }

  network_interface {
    name     = "eth0"
    bridge   = proxmox_virtual_environment_sdn_vnet.srv.id
    firewall = true
  }

  operating_system {
    template_file_id = var.lxc_template_alpine
    type             = "alpine"
  }

  cpu { cores = 1 }
  memory {
    dedicated = 512
    swap      = 256
  }
  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  unprivileged  = true
  start_on_boot = true
}
