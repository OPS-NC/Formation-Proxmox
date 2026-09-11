# ── Le firewall du DATACENTER, en code ───────────────────────────────────────
# Équivalent de /etc/pve/firewall/cluster.fw (modèle : lab/firewall/standalone/cluster.fw.example).
# Tout ce que le TP 09 a écrit à la main est ici, versionné — y compris la matrice
# inter-VNet en FORWARD (TP 09 §5.4) : un paquet qui sort de son VNet est routé par
# l'hôte, et seules les règles FORWARD du Datacenter / du nœud le voient.
#
# 🧠 Même mécanisme que vsrv.fw (firewall.tf) : les règles sont décrites dans des
#    locals, rendues par templates/cluster.fw.tftpl, puis le fichier est DÉPOSÉ par
#    scp. Il ÉCRASE cluster.fw : aucun conflit avec le fichier du TP 09.
#
#    Pourquoi pas les ressources natives du provider (alias, ipset, rules, options) ?
#    Elles ne savent que CRÉER : un alias déjà présent dans cluster.fw (fichier du
#    TP 09 laissé en place, ou reposé après un destroy) fait échouer l'apply sur
#    « alias 'lan_salle' already exists », et Terraform saute en silence tout ce qui
#    en dépend. Un fichier complet est atomique : options et autorisations arrivent
#    ensemble, on ne perd jamais :8006 entre deux ressources.
#
# ⚠ Ce fichier PREND LA MAIN sur cluster.fw : sauvegardez le vôtre avant le premier
#   apply (TP 12 §5). Toute modification faite dans l'UI est écrasée au prochain push.

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
    https    = { proto = "tcp", dport = "443", comment = "HTTPS depuis le poste" }
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
    # Fermer les autres flux inter-zones AVANT les règles de sortie sans destination.
    { action = "DROP", source = "+sdn/vint-all", dest = "+sdn/vsrv-all", comment = "autres int -> srv interdits", log = "info" },
    { action = "DROP", source = "+sdn/vsrv-all", dest = "+sdn/vint-all", comment = "autres srv -> int interdits", log = "info" },
    { action = "DROP", source = "+sdn/vsrv-all", dest = "+sdn/vdmz-all", comment = "autres srv -> dmz interdits", log = "info" },
    # sortie Internet (sans dest : EN DERNIER)
    { action = "ACCEPT", source = "+sdn/vint-all", comment = "int -> Internet libre" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "tcp", dport = "80", comment = "dmz -> Internet HTTP" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "tcp", dport = "443", comment = "dmz -> Internet HTTPS" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "udp", dport = "53", comment = "dmz -> Internet DNS" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "tcp", dport = "53", comment = "dmz -> Internet DNS TCP" },
    { action = "ACCEPT", source = "+sdn/vdmz-all", proto = "udp", dport = "123", comment = "dmz -> Internet NTP" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "tcp", dport = "80", comment = "srv -> Internet HTTP" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "tcp", dport = "443", comment = "srv -> Internet HTTPS" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "udp", dport = "53", comment = "srv -> Internet DNS" },
    { action = "ACCEPT", source = "+sdn/vsrv-all", proto = "tcp", dport = "53", comment = "srv -> Internet DNS TCP" },
  ]

  # Produit cartésien réseaux × flux → une règle FORWARD par couple, ordre stable.
  # L'ajout HTTPS est standalone : conserver les autorisations EVPN historiques telles quelles.
  fw_forward_rules = flatten([
    for net_name, net in local.fw_nets : [
      for flow_name, flow in local.fw_lan_to_nets : {
        key     = "${net_name}-${flow_name}"
        dest    = net_name
        proto   = flow.proto
        dport   = flow.dport
        comment = "${flow.comment} → ${net.comment}"
      } if net_name != "net_evpn" || flow_name != "https"
    ]
  ])
}

# ── Alias, IPSet, groupes ────────────────────────────────────────────────────
locals {
  fw_aliases = concat(
    [
      { name = "lan_salle", cidr = "172.30.30.0/24", comment = "LAN physique de la salle" },
      { name = "gw_salle", cidr = "172.30.30.2", comment = "routeur / accès Internet" },
    ],
    [for name, net in local.fw_nets : { name = name, cidr = net.cidr, comment = net.comment }],
  )

  # IPSet : qui a le droit d'administrer les nœuds
  fw_ipsets = {
    management = {
      comment = "tout ce qui peut administrer les nœuds"
      entries = [{ cidr = "172.30.30.0/24", comment = "LAN de la salle" }]
    }
  }

  # Groupes de sécurité réutilisables (étage ④ : à attacher aux VM)
  fw_groups = {
    pve-admin = {
      comment = "accès à l'administration Proxmox"
      rules = [
        { source = "+management", proto = "tcp", dport = "8006", comment = "interface web" },
        { source = "+management", proto = "tcp", dport = "22", comment = "SSH" },
        { source = "+management", proto = "tcp", dport = "3128", comment = "proxy SPICE" },
        { source = "+management", proto = "tcp", dport = "5900:5999", comment = "consoles VNC" },
      ]
    }
    srv-web = {
      comment = "un serveur web générique"
      rules = [
        { proto = "tcp", dport = "80" },
        { proto = "tcp", dport = "443" },
      ]
    }
    srv-db = {
      comment = "une base, ouverte à l'interne seulement"
      rules = [
        { source = "+sdn/vint-all", proto = "tcp", dport = "5432" },
        { source = "+sdn/vint-all", proto = "tcp", dport = "3306" },
      ]
    }
  }
}

# ── Les règles du Datacenter, dans l'ordre du fichier ────────────────────────
# Première correspondance gagnante : les DROP explicites précèdent les règles sans dest.
locals {
  fw_cluster_rules = concat(
    # ── Administration des nœuds ──
    [
      { source = "+management", proto = "tcp", dport = "8006", comment = "UI Proxmox" },
      { source = "+management", proto = "tcp", dport = "22", comment = "SSH" },
      { source = "+management", proto = "tcp", dport = "3128", comment = "SPICE" },
      { source = "+management", proto = "tcp", dport = "5900:5999", comment = "noVNC" },
    ],
    # ── Cluster : NE JAMAIS OUBLIER, sinon le cluster se casse (jour 4) ──
    [
      { source = "lan_salle", proto = "udp", dport = "5405:5412", comment = "Corosync — VITAL" },
      { source = "lan_salle", proto = "tcp", dport = "60000:60050", comment = "migration de VM" },
    ],
    # ── SDN EVPN (jour 4) ──
    [
      { source = "lan_salle", proto = "udp", dport = "4789", comment = "VXLAN" },
      { source = "lan_salle", proto = "tcp", dport = "179", comment = "BGP" },
    ],
    # ── Stockage et sauvegarde : rien à ouvrir pour le NFS, c'est le nœud qui initie ──
    [{ source = "lan_salle", proto = "tcp", dport = "8007", comment = "UI PBS" }],
    # ── Diagnostic ──
    [{ source = "lan_salle", proto = "icmp", comment = "ping des nœuds" }],
    # ── Services portés par le nœud : la gateway des VNets est une IP de l'hôte ──
    # policy_in: DROP s'applique aussi aux VM. Le DHCP part de 0.0.0.0 : aucun IPSet ne le
    # matche, d'où le filtre par interface. Les IPSets +sdn/* sont utilisables ici.
    [for vnet in ["vint", "vdmz", "vsrv"] :
      { iface = vnet, proto = "udp", dport = "67", comment = "DHCP ${vnet}" }
    ],
    [for r in local.fw_gw_rules :
      { source = "+sdn/${r.vnet}-all", proto = r.proto, dport = r.dport, comment = "${r.comment} depuis ${r.vnet}" }
    ],
    # ── ⭐ Depuis le poste vers TOUS les réseaux privés (FORWARD : trafic routé par le nœud) ──
    # C'est ce qui permet à Ansible et à vos « ssh eleve@10.10.x.y » de joindre les VM
    # directement depuis le PC, sans rebond par le nœud.
    [for r in local.fw_forward_rules :
      { dir = "FORWARD", source = "lan_salle", dest = r.dest, proto = r.proto, dport = r.dport, comment = r.comment }
    ],
    # Interfaces de supervision depuis le LAN (vers SERVICES uniquement).
    [for port in ["3000", "9090"] :
      { dir = "FORWARD", source = "lan_salle", dest = "net_services", proto = "tcp", dport = port, comment = "supervision depuis le LAN" }
    ],
    # ── Zone HOST : le trafic ROUTÉ (inter-VNet, sortie Internet) = la matrice, dans l'ordre ──
    [for r in local.fw_matrix : merge(r, { dir = "FORWARD" })],
  )
}

# ── Rendu : une règle → une ligne cluster.fw ─────────────────────────────────
# Chaque champ absent vaut null et disparaît de la ligne. Format Proxmox :
#   DIR ACTION [-i iface] [-source X] [-dest Y] [-p proto] [-dport N] -log LEVEL # commentaire
locals {
  fw_rule_defaults = {
    dir   = "IN", action = "ACCEPT", iface = null, source = null, dest = null,
    proto = null, dport = null, log = "nolog", comment = null
  }

  fw_cluster_lines = [
    for r in [for x in local.fw_cluster_rules : merge(local.fw_rule_defaults, x)] :
    format("%s%s",
      join(" ", compact([
        r.dir, r.action,
        r.iface == null ? "" : "-i ${r.iface}",
        r.source == null ? "" : "-source ${r.source}",
        r.dest == null ? "" : "-dest ${r.dest}",
        r.proto == null ? "" : "-p ${r.proto}",
        r.dport == null ? "" : "-dport ${r.dport}",
        "-log ${r.log}",
      ])),
      r.comment == null ? "" : " # ${r.comment}",
    )
  ]

  fw_group_lines = {
    for name, g in local.fw_groups : name => {
      comment = g.comment
      lines = [
        for r in [for x in g.rules : merge(local.fw_rule_defaults, x)] :
        format("%s%s",
          join(" ", compact([
            r.dir, r.action,
            r.source == null ? "" : "-source ${r.source}",
            r.dest == null ? "" : "-dest ${r.dest}",
            r.proto == null ? "" : "-p ${r.proto}",
            r.dport == null ? "" : "-dport ${r.dport}",
            "-log ${r.log}",
          ])),
          r.comment == null ? "" : " # ${r.comment}",
        )
      ]
    }
  }

  cluster_fw = templatefile("${path.module}/templates/cluster.fw.tftpl", {
    aliases = local.fw_aliases
    ipsets  = local.fw_ipsets
    groups  = local.fw_group_lines
    rules   = local.fw_cluster_lines
  })
}

resource "local_file" "cluster_fw" {
  content         = local.cluster_fw
  filename        = "${path.module}/generated/cluster.fw"
  file_permission = "0640"
}

# ── Le dépôt ─────────────────────────────────────────────────────────────────
# Le fichier est écrit en une fois : les autorisations et policy_in/forward: DROP
# arrivent ensemble, pas de fenêtre sans :8006. Le trigger content_md5 rejoue le
# push à chaque changement de règle, et seulement là.
#
# Au destroy, le fichier RESTE sur le nœud : Terraform cesse de le gérer, le nœud
# garde son firewall (et vint.fw / vdmz.fw gardent l'alias lan_salle). Pour revenir
# à l'état TP 09, reposez lab/firewall/standalone/cluster.fw.example (TP 12 §9).
resource "terraform_data" "push_cluster_fw" {
  # Les IPSets +sdn/vsrv-* doivent exister : sinon proxmox-firewall saute ces règles.
  depends_on = [proxmox_sdn_applier.apply]

  input = { host = var.pve_host }

  triggers_replace = [local_file.cluster_fw.content_md5]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@${var.pve_host}"
      echo ">> dépôt de cluster.fw sur ${var.pve_host}:/etc/pve/firewall/"
      $SSH 'mkdir -p /etc/pve/firewall'
      scp -o BatchMode=yes -o StrictHostKeyChecking=no ${local_file.cluster_fw.filename} \
          root@${var.pve_host}:/etc/pve/firewall/cluster.fw
      $SSH 'systemctl restart proxmox-firewall'
      echo ">> cluster.fw déposé, proxmox-firewall redémarré"
    EOT
  }
}
