# ── Le firewall du DATACENTER, en code ───────────────────────────────────────
# Équivalent de /etc/pve/firewall/cluster.fw (modèle : lab/firewall/cluster.fw.example),
# porté par des ressources NATIVES du provider : options, alias, IPSet, groupes de
# sécurité, règles. Tout ce que le TP 09 a écrit à la main est ici, versionné — y compris
# la matrice inter-VNet en FORWARD (TP 09 §5.4) : un paquet qui sort de son VNet est routé
# par l'hôte, et seules les règles FORWARD du Datacenter / du nœud le voient.
#
# ⚠ Ce fichier PREND LA MAIN sur cluster.fw. Avant le premier apply, retirez le
#   fichier écrit au TP 09 (voir TP 12 §5) : Terraform le regénère entièrement,
#   et il ne veut pas cohabiter avec des règles qu'il ne connaît pas.
#
# 🧠 Ordre des opérations : les règles d'autorisation sont créées AVANT que les
#    politiques passent en DROP (depends_on sur les options). Sinon vous perdez :8006.

locals {
  # Les réseaux privés du nœud : ceux du TP 08 (vint, vdmz), celui-ci (vsrv),
  # et les VNets EVPN du jour 4. Ils partagent la même politique d'accès depuis le LAN.
  fw_nets = {
    net_internal = { cidr = local.net_int, comment = "zone interne (TP 08)" }
    net_dmz      = { cidr = local.net_dmz, comment = "DMZ (TP 08)" }
    net_services = { cidr = local.net_srv, comment = "zone services (TP 12)" }
    net_evpn     = { cidr = "10.60.0.0/16", comment = "VNets EVPN du jour 4 (TP 17)" }
  }

  # Ce que le PC (et tout le LAN de la salle) peut atteindre dans CHAQUE réseau privé.
  # C'est ce qui rend possible l'accès direct « ssh eleve@10.10.x.y » depuis le poste,
  # via la route 10.10.0.0/16 → nœud posée au TP 07.
  fw_lan_to_nets = {
    ssh      = { proto = "tcp", dport = "22", comment = "SSH depuis le poste (Ansible, TP 13)" }
    http     = { proto = "tcp", dport = "80", comment = "HTTP depuis le poste" }
    postgres = { proto = "tcp", dport = "5432", comment = "PostgreSQL depuis le poste" }
    icmp     = { proto = "icmp", dport = null, comment = "ping depuis le poste" }
  }

  # Ce que les VM peuvent demander à leur gateway (une IP de l'hôte) : DNS et ping.
  fw_gw_rules = flatten([
    for vnet in ["vint", "vdmz", "vsrv"] : [
      { key = "${vnet}-dns-udp", vnet = vnet, proto = "udp", dport = "53", comment = "DNS" },
      { key = "${vnet}-dns-tcp", vnet = vnet, proto = "tcp", dport = "53", comment = "DNS" },
      { key = "${vnet}-icmp", vnet = vnet, proto = "icmp", dport = null, comment = "ping gateway" },
    ]
  ])

  # La matrice de flux du TP 09 §1 (+ la zone services du TP 12), en FORWARD. L'ORDRE compte.
  fw_matrix = [
    # interne → DMZ : liste blanche, puis DROP
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vdmz-all", proto = "tcp", dport = "22", comment = "int -> dmz SSH" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vdmz-all", proto = "tcp", dport = "80", comment = "int -> dmz HTTP" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vdmz-all", proto = "tcp", dport = "443", comment = "int -> dmz HTTPS" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vdmz-all", proto = "icmp", comment = "int -> dmz ping" },
    { action = "DROP", source = "+sdn/vint-all", dest = "+sdn/vdmz-all", comment = "tout autre int -> dmz", log = "info" },
    { action = "DROP", source = "+sdn/vdmz-all", dest = "+sdn/vint-all", comment = "DMZ -> INTERNE interdit", log = "warning" },
    # services (vsrv, TP 12) : supervision et administration
    { action = "ACCEPT", source = "+sdn/vsrv-all", dest = "+sdn/vint-all", proto = "tcp", dport = "9100", comment = "srv scrape int" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", dest = "+sdn/vdmz-all", proto = "tcp", dport = "9100", comment = "srv scrape dmz" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", dest = "+sdn/vint-all", proto = "tcp", dport = "22", comment = "srv -> int SSH", log = "info" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vsrv-all", proto = "tcp", dport = "22", comment = "admin int -> srv SSH" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vsrv-all", proto = "tcp", dport = "3000", comment = "admin int -> srv Grafana" },
    { action = "ACCEPT", source = "+sdn/vint-all", dest = "+sdn/vsrv-all", proto = "tcp", dport = "9090", comment = "admin int -> srv Prometheus" },
    { action = "DROP", source = "+sdn/vdmz-all", dest = "+sdn/vsrv-all", comment = "DMZ -> SERVICES interdit", log = "warning" },
    # sortie Internet (sans dest : EN DERNIER)
    { action = "ACCEPT", source = "+sdn/vint-all", comment = "int -> Internet libre" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "tcp", dport = "80", comment = "dmz -> Internet HTTP" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "tcp", dport = "443", comment = "dmz -> Internet HTTPS" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "udp", dport = "53", comment = "dmz -> Internet DNS" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "udp", dport = "123", comment = "dmz -> Internet NTP" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "tcp", dport = "80", comment = "srv -> Internet HTTP" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "tcp", dport = "443", comment = "srv -> Internet HTTPS" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "udp", dport = "53", comment = "srv -> Internet DNS" },
  ]

  # Produit cartésien réseaux × flux → une règle FORWARD par couple, ordre stable.
  fw_forward_rules = flatten([
    for net_name, net in local.fw_nets : [
      for flow_name, flow in local.fw_lan_to_nets : {
        key     = "${net_name}-${flow_name}"
        dest    = net_name
        proto   = flow.proto
        dport   = flow.dport
        comment = "${flow.comment} → ${net.comment}"
      }
    ]
  ])
}

# ── Alias ────────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_firewall_alias" "lan_salle" {
  name    = "lan_salle"
  cidr    = "172.30.30.0/24"
  comment = "LAN physique de la salle"
}

resource "proxmox_virtual_environment_firewall_alias" "gw_salle" {
  name    = "gw_salle"
  cidr    = "172.30.30.2"
  comment = "routeur / accès Internet"
}

resource "proxmox_virtual_environment_firewall_alias" "nets" {
  for_each = local.fw_nets

  name    = each.key
  cidr    = each.value.cidr
  comment = each.value.comment
}

# ── IPSet : qui a le droit d'administrer les nœuds ───────────────────────────
resource "proxmox_virtual_environment_firewall_ipset" "management" {
  name    = "management"
  comment = "tout ce qui peut administrer les nœuds"

  cidr {
    name    = "172.30.30.0/24"
    comment = "LAN de la salle"
  }
}

# ── Groupes de sécurité réutilisables (étage ④ : à attacher aux VM) ──────────
resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_admin" {
  name    = "pve-admin"
  comment = "accès à l'administration Proxmox"

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "8006"
    comment = "interface web"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "22"
    comment = "SSH"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "3128"
    comment = "proxy SPICE"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "5900:5999"
    comment = "consoles VNC"
    log     = "nolog"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "srv_web" {
  name    = "srv-web"
  comment = "un serveur web générique"

  rule {
    type   = "in"
    action = "ACCEPT"
    proto  = "tcp"
    dport  = "80"
    log    = "nolog"
  }
  rule {
    type   = "in"
    action = "ACCEPT"
    proto  = "tcp"
    dport  = "443"
    log    = "nolog"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "srv_db" {
  name    = "srv-db"
  comment = "une base, ouverte à l'interne seulement"

  rule {
    type   = "in"
    action = "ACCEPT"
    source = "+sdn/vint-all"
    proto  = "tcp"
    dport  = "5432"
    log    = "nolog"
  }
  rule {
    type   = "in"
    action = "ACCEPT"
    source = "+sdn/vint-all"
    proto  = "tcp"
    dport  = "3306"
    log    = "nolog"
  }
}

# ── Les règles du datacenter ─────────────────────────────────────────────────
# Sans node_name ni vm_id, la ressource cible /cluster/firewall/rules.
resource "proxmox_virtual_environment_firewall_rules" "cluster" {
  depends_on = [
    proxmox_virtual_environment_firewall_alias.lan_salle,
    proxmox_virtual_environment_firewall_alias.nets,
    proxmox_virtual_environment_firewall_ipset.management,
  ]

  # ── Administration des nœuds ──
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "8006"
    comment = "UI Proxmox"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "22"
    comment = "SSH"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "3128"
    comment = "SPICE"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+management"
    proto   = "tcp"
    dport   = "5900:5999"
    comment = "noVNC"
    log     = "nolog"
  }

  # ── Cluster : NE JAMAIS OUBLIER, sinon le cluster se casse (jour 4) ──
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "udp"
    dport   = "5405:5412"
    comment = "Corosync — VITAL"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "tcp"
    dport   = "60000:60050"
    comment = "migration de VM"
    log     = "nolog"
  }

  # ── SDN EVPN (jour 4) ──
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "udp"
    dport   = "4789"
    comment = "VXLAN"
    log     = "nolog"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "tcp"
    dport   = "179"
    comment = "BGP"
    log     = "nolog"
  }

  # ── Stockage et sauvegarde ──
  # Rien à ouvrir en entrée pour le NFS : c'est le nœud qui initie vers le poste.
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "tcp"
    dport   = "8007"
    comment = "UI PBS"
    log     = "nolog"
  }

  # ── Diagnostic ──
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "lan_salle"
    proto   = "icmp"
    comment = "ping des nœuds"
    log     = "nolog"
  }

  # ── Services d'infrastructure portés par le nœud : la gateway des VNets est une IP de l'hôte ──
  # policy_in: DROP s'applique aussi aux VM. Le DHCP part de 0.0.0.0 : aucun IPSet ne le
  # matche, d'où le filtre par interface. Les IPSets +sdn/* sont utilisables ici.
  dynamic "rule" {
    for_each = toset(["vint", "vdmz", "vsrv"])
    content {
      type    = "in"
      action  = "ACCEPT"
      iface   = rule.value
      proto   = "udp"
      dport   = "67"
      comment = "DHCP ${rule.value}"
      log     = "nolog"
    }
  }
  dynamic "rule" {
    for_each = { for r in local.fw_gw_rules : r.key => r }
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = "+sdn/${rule.value.vnet}-all"
      proto   = rule.value.proto
      dport   = rule.value.dport
      comment = "${rule.value.comment} depuis ${rule.value.vnet}"
      log     = "nolog"
    }
  }

  # ── ⭐ Depuis le poste vers TOUS les réseaux privés : SSH, HTTP, PostgreSQL, ping ──
  # Ces règles FORWARD traversent le nœud (policy_forward: DROP sinon). Elles sont
  # ce qui permet à Ansible et à vos « ssh eleve@10.10.x.y » de joindre les VM
  # directement depuis le PC — sans rebond par le nœud.
  dynamic "rule" {
    for_each = { for r in local.fw_forward_rules : r.key => r }
    content {
      type    = "forward"
      action  = "ACCEPT"
      source  = "lan_salle"
      dest    = rule.value.dest
      proto   = rule.value.proto
      dport   = rule.value.dport
      comment = rule.value.comment
      log     = "nolog"
    }
  }

  # ── Zone HOST : le trafic ROUTÉ par le nœud (inter-VNet, sortie Internet) ──
  # C'est ICI que vit la segmentation inter-zones (TP 09 §5.4), pas dans les .fw de VNet.
  # Les DROP explicites précèdent les règles fourre-tout sans dest.
  dynamic "rule" {
    for_each = { for i, r in local.fw_matrix : format("%02d", i) => r }
    content {
      type    = "forward"
      action  = rule.value.action
      source  = rule.value.source
      dest    = lookup(rule.value, "dest", null)
      proto   = lookup(rule.value, "proto", null)
      dport   = lookup(rule.value, "dport", null)
      comment = rule.value.comment
      log     = lookup(rule.value, "log", "nolog")
    }
  }
}

# ── Les options : EN DERNIER, une fois les règles en place ───────────────────
resource "proxmox_virtual_environment_cluster_firewall" "options" {
  depends_on = [proxmox_virtual_environment_firewall_rules.cluster]

  enabled = true

  input_policy   = "DROP"
  output_policy  = "ACCEPT"
  forward_policy = "DROP" # ★ tout le trafic transitant par le nœud, sauf règles FORWARD

  log_ratelimit {
    enabled = true
    rate    = "5/second"
    burst   = 20
  }
}
