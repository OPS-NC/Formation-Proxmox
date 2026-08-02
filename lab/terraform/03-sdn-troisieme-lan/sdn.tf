locals {
  net_srv = "10.${var.eleve}.30.0/24"
  gw_srv  = "10.${var.eleve}.30.1"
  net_int = "10.${var.eleve}.10.0/24"
  net_dmz = "10.${var.eleve}.20.0/24"

  template_id = coalesce(var.template_debian, var.eleve * 100 + 90)
}

# ── La zone ──────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_zone_simple" "srv" {
  id    = "zsrv"
  nodes = [var.pve_node]
  ipam  = "pve"
  dhcp  = "dnsmasq"
  mtu   = 1500
}

# ── Le VNet ──────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_vnet" "srv" {
  id    = "vsrv"
  zone  = proxmox_virtual_environment_sdn_zone_simple.srv.id
  alias = "Services infra e${var.eleve}"
}

# ── Le subnet ────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_subnet" "srv" {
  subnet  = local.net_srv
  vnet    = proxmox_virtual_environment_sdn_vnet.srv.id
  type    = "subnet"
  gateway = local.gw_srv
  snat    = true

  dhcp_range {
    start_address = "10.${var.eleve}.30.100"
    end_address   = "10.${var.eleve}.30.200"
  }
}

# ── L'apply SDN ──────────────────────────────────────────────────────────────
# Le SDN est transactionnel : tant qu'on n'applique pas, rien n'existe
# réellement sur le nœud. Selon la version du provider, l'apply peut être
# automatique — ce déclencheur explicite garantit le comportement.
#
# Si votre provider expose « auto_apply » sur les ressources SDN, préférez-le :
#   terraform providers schema -json | jq '.. | .auto_apply? // empty'
resource "terraform_data" "sdn_apply" {
  triggers_replace = [
    proxmox_virtual_environment_sdn_zone_simple.srv.id,
    proxmox_virtual_environment_sdn_vnet.srv.id,
    proxmox_virtual_environment_sdn_subnet.srv.subnet,
  ]

  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no root@${var.pve_host} 'pvesh set /cluster/sdn' && sleep 5"
  }
}
