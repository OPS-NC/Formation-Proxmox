locals {
  net_srv = "10.${var.eleve}.30.0/24"
  gw_srv  = "10.${var.eleve}.30.1"
  net_int = "10.${var.eleve}.10.0/24"
  net_dmz = "10.${var.eleve}.20.0/24"

  template_id = coalesce(var.template_debian, var.eleve * 100 + 90)
}

# ── L'apply SDN, en deux temps ───────────────────────────────────────────────
# Le SDN est transactionnel : tant qu'on n'a pas appliqué, rien n'existe
# réellement sur le nœud. Le provider expose une ressource dédiée pour ça —
# inutile de bricoler un local-exec « pvesh set /cluster/sdn » en SSH.
#
# 🧠 Pourquoi DEUX appliers ?
#   · « finalizer » ne fait rien à la création, mais tous les objets SDN en
#     dépendent. Terraform détruit dans l'ordre INVERSE des dépendances : le
#     finalizer est donc détruit EN DERNIER, et son apply-on-destroy nettoie
#     le nœud une fois les objets retirés de la configuration.
#   · « apply » dépend des objets : il s'exécute APRÈS leur création, et son
#     replace_triggered_by le rejoue à chaque modification.
resource "proxmox_virtual_environment_sdn_applier" "finalizer" {}

# ── La zone ──────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_zone_simple" "srv" {
  id    = "zsrv"
  nodes = [var.pve_node]
  ipam  = "pve"
  dhcp  = "dnsmasq"
  mtu   = 1500

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

# ── Le VNet ──────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_vnet" "srv" {
  id    = "vsrv"
  zone  = proxmox_virtual_environment_sdn_zone_simple.srv.id
  alias = "Services infra e${var.eleve}"

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

# ── Le subnet ────────────────────────────────────────────────────────────────
# ⚠ L'argument s'appelle « cidr », pas « subnet » : le provider ne calque pas
#   le nommage de l'API Proxmox (où pvesh attend --subnet et --type subnet).
#   « dhcp_range » est un ATTRIBUT (avec un « = »), pas un bloc.
resource "proxmox_virtual_environment_sdn_subnet" "srv" {
  cidr    = local.net_srv
  vnet    = proxmox_virtual_environment_sdn_vnet.srv.id
  gateway = local.gw_srv
  snat    = true

  dhcp_range = {
    start_address = "10.${var.eleve}.30.100"
    end_address   = "10.${var.eleve}.30.200"
  }

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

# ── L'apply proprement dit ───────────────────────────────────────────────────
resource "proxmox_virtual_environment_sdn_applier" "apply" {
  depends_on = [
    proxmox_virtual_environment_sdn_zone_simple.srv,
    proxmox_virtual_environment_sdn_vnet.srv,
    proxmox_virtual_environment_sdn_subnet.srv,
  ]

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_sdn_zone_simple.srv,
      proxmox_virtual_environment_sdn_vnet.srv,
      proxmox_virtual_environment_sdn_subnet.srv,
    ]
  }
}
