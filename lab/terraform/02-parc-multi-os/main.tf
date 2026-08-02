locals {
  # VMID par défaut : eleve*100 + 90/91/92, conformément au TP 10
  templates = merge({
    debian = var.eleve * 100 + 90
    ubuntu = var.eleve * 100 + 91
    rocky  = var.eleve * 100 + 92
  }, var.templates)

  # Un VMID stable et déterministe pour chaque machine de la map
  machine_names = sort(keys(var.machines))
  vmids = {
    for i, name in local.machine_names :
    name => var.eleve * 100 + 22 + i
  }
}

resource "proxmox_virtual_environment_vm" "parc" {
  for_each = var.machines

  name        = "${each.key}-e${var.eleve}"
  description = "Déployée par Terraform — TP 11"
  node_name   = var.pve_node
  vm_id       = local.vmids[each.key]
  pool_id     = "eleve${var.eleve}"

  # ⭐ Le fil rouge : ces tags deviennent des groupes Ansible au TP 13
  tags = concat(["terraform", "eleve${var.eleve}"], each.value.tags)

  clone {
    vm_id = local.templates[each.value.template]
    full  = false
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
  vm_id     = var.eleve * 100 + 16
  pool_id   = "eleve${var.eleve}"
  tags      = ["terraform", "cache", "dmz", "alpine", "eleve${var.eleve}"]

  description = "Conteneur Alpine déployé par Terraform — TP 11"

  initialization {
    hostname = "ct-cache-e${var.eleve}"

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
