locals {
  template_id = coalesce(var.template_debian, var.eleve * 100 + 90)
  vm_id       = var.eleve * 100 + 21
}

resource "proxmox_virtual_environment_vm" "web" {
  name        = "web01-e${var.eleve}"
  description = "Première VM Terraform — TP 11"
  node_name   = var.pve_node
  vm_id       = local.vm_id
  pool_id     = "eleve${var.eleve}"

  # ⭐ Ces tags pilotent l'inventaire Ansible du TP 13
  tags = ["terraform", "web", "dmz", "debian", "eleve${var.eleve}"]

  clone {
    vm_id = local.template_id
    full  = false # linked clone : instantané et économe
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
