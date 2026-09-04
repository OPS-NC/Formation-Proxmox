# SDN Proxmox VE 9 — la référence complète 🌐

> Ce document n'est pas un TP. C'est **la carte du territoire** : tout ce que le SDN
> de Proxmox VE 9 sait faire aujourd'hui, ce que chaque brique apporte réellement,
> et — dernière partie — **pourquoi notre lab utilise EVPN** et pas autre chose.
> À lire une fois avant le jour 2, à relire avant le jour 4.
>
> 📖 Doc officielle : <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html>

---

## 1. À quoi sert le SDN, concrètement ?

Avant le SDN, configurer le réseau d'un cluster Proxmox voulait dire :
éditer `/etc/network/interfaces` **sur chaque nœud**, à la main, en espérant ne pas
avoir fait de faute de frappe sur le nœud 5. Un VLAN oublié = une VM injoignable
après migration.

Le SDN apporte trois choses :

1. **Une configuration réseau centralisée et clusterisée.** On décrit le réseau une
   fois dans `/etc/pve/sdn/`, Proxmox génère la conf de chaque nœud.
2. **Un modèle en couches** (zone → VNet → subnet) qui découple le réseau *logique*
   du réseau *physique*.
3. **Des services intégrés** : IPAM, DHCP, DNS, firewall par VNet, overlay VXLAN,
   routage BGP/EVPN — sans installer un contrôleur SDN tiers.

### Le modèle en 3 étages 🧅

```
   ┌────────────────────────────────────────────────────────────┐
   │  ZONE          « Comment on transporte les paquets »       │
   │  (simple / vlan / qinq / vxlan / evpn)                     │
   │  → choisit la technologie et les nœuds concernés           │
   │                                                            │
   │    ┌──────────────────────────────────────────────────┐    │
   │    │  VNET       « Un réseau L2 »                     │    │
   │    │  → apparaît comme un bridge sur le nœud          │    │
   │    │  → c'est ce qu'on branche sur la carte de la VM  │    │
   │    │                                                  │    │
   │    │    ┌────────────────────────────────────────┐    │    │
   │    │    │  SUBNET   « Un plan d'adressage L3 »   │    │    │
   │    │    │  → CIDR, gateway, SNAT, DHCP, IPAM     │    │    │
   │    │    └────────────────────────────────────────┘    │    │
   │    └──────────────────────────────────────────────────┘    │
   └────────────────────────────────────────────────────────────┘

   + éventuellement :  CONTROLLER  (plan de contrôle : BGP / EVPN / IS-IS)
                       FABRIC      (underlay routé : OpenFabric / OSPF / BGP)
                       IPAM        (qui attribue les IP)
                       DNS         (enregistrement automatique des noms)
```

**Règle mnémotechnique** : *la zone c'est le tuyau, le VNet c'est le câble,
le subnet c'est l'étiquette qu'on colle dessus.*

---

## 2. Les types de zones

### 2.1 Zone `Simple` — le bac à sable local 🪣

Crée un bridge Linux **local au nœud**, isolé du réseau physique. Proxmox peut y
poser une gateway et faire du **SNAT** vers l'extérieur : c'est le « routeur maison »
intégré.

```
     VM ──┐
     VM ──┼── vnet (bridge local) ── [gw 10.10.10.1] ── SNAT ── vmbr0 ── LAN
     VM ──┘
              ← tout ceci existe UNIQUEMENT sur ce nœud →
```

| Apporte | Limite |
|---|---|
| Zéro dépendance au réseau physique | **Pas de L2 entre nœuds** : deux VM du même VNet sur deux nœuds différents ne se voient pas |
| SNAT intégré → Internet immédiat | Le même subnet sur 2 nœuds = 2 réseaux distincts qui s'ignorent |
| IPAM + DHCP fonctionnels | La gateway est locale : pas de redondance |
| Idéal pour labs, DMZ mono-nœud, réseaux de service | |

👉 **On l'utilise au jour 2** (TP 08) : chaque stagiaire est encore sur un nœud isolé.

---

### 2.2 Zone `VLAN` — le classique du datacenter 🏷️

Le VNet devient un VLAN tagué sur un bridge existant (`vmbr0`) ou un OVS.

```
   nœud1                    nœud2
   VM(vlan 100) ─┐          ┌─ VM(vlan 100)
                 └ vmbr0 ═══ TRUNK ═══ vmbr0 ┘
                        (switch physique)
```

| Apporte | Limite |
|---|---|
| L2 étendu entre tous les nœuds, performances natives | **Le switch doit être configuré en trunk** |
| Simple, éprouvé, débogable au tcpdump | Limité à 4094 VLAN |
| Pas d'encapsulation → MTU intact | Le routage inter-VLAN se fait ailleurs (routeur/L3 switch) |

🪤 **Dans notre lab : inutilisable.** On n'a pas la main sur le switch.

---

### 2.3 Zone `QinQ` — le VLAN dans le VLAN 🪆

Empile un tag externe (Service VLAN, S-VLAN) et un tag interne (Customer VLAN).
Chaque « client » a son propre espace de 4094 VLAN à l'intérieur d'un VLAN externe.

```
   Trame :  [ S-VLAN 500 ][ C-VLAN 100 ][ payload ]
                  ↑              ↑
             tag opérateur   tag client
```

| Apporte | Limite |
|---|---|
| Multi-tenant sur infra VLAN, ~16 M combinaisons | Le switch doit supporter le 802.1ad |
| Isolation forte entre clients | MTU −4 octets |
| | Toujours dépendant du réseau physique |

🪤 Notre lab : idem, hors-jeu.

---

### 2.4 Zone `VXLAN` — l'overlay L2 pur 📦

Encapsule de l'Ethernet dans de l'UDP (port **4789**). Le réseau physique ne voit
que des paquets IP entre nœuds ; il ignore totalement les VLAN des VM.

```
   VM ── vnet ──╮                                    ╭── vnet ── VM
                ├─ VTEP ══ UDP/4789 ══ LAN ══ VTEP ──┤
   nœud1        ╯          (underlay IP)             ╰       nœud2

   Paquet réel :  [ IP nœud1 → IP nœud2 ][ UDP 4789 ][ VXLAN VNI ][ trame VM ]
                  └──────── 50 octets d'entête ────────┘
```

| Apporte | Limite |
|---|---|
| L2 étendu **sans toucher au switch** ✨ | **MTU −50** : il faut baisser le MTU des VM à 1450 (ou monter l'underlay à 1550+) |
| Fonctionne au-dessus de n'importe quel réseau IP | Pas de plan de contrôle : le *flooding* BUM se fait vers tous les peers |
| Jusqu'à 16 M de VNI | **Pas de routage** : pas de gateway, pas de sortie Internet native |

🧠 VXLAN seul = un gros switch virtuel distribué. Utile, mais vos VM n'ont
toujours pas de passerelle. Pour cela → EVPN.

---

### 2.5 Zone `EVPN` — l'overlay L3 routé 👑

VXLAN pour le transport + **BGP EVPN** pour le plan de contrôle + un **VRF** par zone
pour le routage. C'est le modèle des datacenters modernes, et Proxmox l'embarque via
**FRRouting**.

Ce que ça change tout :

- **Anycast gateway** : la même IP de gateway (`10.60.10.1`) et la **même MAC**
  existent simultanément sur *tous* les nœuds. Une VM parle toujours à sa gateway
  locale, même après migration à chaud. Aucune interruption.
- **Routage inter-VNet** : deux VNets de la même zone EVPN se routent entre eux
  automatiquement, dans le VRF de la zone.
- **Exit nodes** : un ou plusieurs nœuds désignés annoncent une **route par défaut**
  dans le fabric EVPN. C'est la porte de sortie vers le monde réel.
- **SNAT sur exit node** : les paquets sortants sont natés derrière l'IP du nœud
  de sortie → Internet fonctionne sans que le routeur amont connaisse vos subnets.

```
              ☁ Internet
                   │
            172.30.30.2
                   │
   ════════════ LAN PHYSIQUE (underlay) ════════════
      │            │            │            │
   ┌──┴───┐     ┌──┴───┐     ┌──┴───┐     ┌──┴───┐
   │ pve1 │     │ pve2 │     │ pve3 │     │ pve4 │
   │EXIT ★│     │EXIT  │     │      │     │      │
   └──┬───┘     └──┬───┘     └──┬───┘     └──┬───┘
      │            │            │            │
   ┌──┴────────────┴────────────┴────────────┴───┐
   │        VRF « zevpn »  (overlay VXLAN)       │
   │  gw anycast 10.60.10.1 présente sur CHAQUE  │
   │  nœud, même MAC partout                     │
   └──┬──────────────┬──────────────┬────────────┘
      │              │              │
    VM web         VM app         VM db
   10.60.10.x     10.60.20.x     10.60.30.x
```

**Options importantes de la zone EVPN :**

| Option | Rôle |
|---|---|
| `controller` | Le contrôleur EVPN (BGP) associé |
| `vrf-vxlan` | VNI dédié au VRF (routage L3), distinct des VNI des VNets |
| `mac` | MAC de l'anycast gateway (générée sinon) |
| `exitnodes` | Liste des nœuds qui annoncent la route par défaut |
| `exitnodes-primary` | **Force tout le trafic sortant par ce nœud** — obligatoire avec SNAT (voir §7) |
| `exitnodes-local-routing` | Permet à l'hôte Proxmox lui-même de joindre les IP des VM |
| `advertise-subnets` | Annonce les subnets entiers (routes type-5) et pas seulement les /32 apprises par ARP. Indispensable pour les *silent hosts*, les IP secondaires, les conteneurs derrière une VM |
| `disable-arp-nd-suppression` | À activer si vous faites des IP flottantes / VRRP dans le VNet |
| `rt-import` | Importe des route-targets externes (interconnexion avec un vrai fabric DC) |
| `mtu` | **1450 par défaut** — ne pas y toucher sans savoir pourquoi |

---

### 2.6 Tableau de décision ⚖️

| Question | Simple | VLAN | QinQ | VXLAN | EVPN |
|---|:---:|:---:|:---:|:---:|:---:|
| Besoin d'accès au switch ? | non | **oui** | **oui** | non | non |
| L2 entre nœuds ? | non | oui | oui | oui | oui |
| Routage L3 intégré ? | local | non | non | non | **oui** |
| Gateway redondante (anycast) ? | non | non | non | non | **oui** |
| Sortie Internet native ? | SNAT local | via routeur | via routeur | non | **exit nodes + SNAT** |
| Coût en MTU | 0 | 0 | −4 | −50 | −50 |
| Complexité | ★ | ★★ | ★★★ | ★★★ | ★★★★ |

---

## 3. Les Fabrics (nouveauté PVE 9) 🕸️

Une **fabric** construit l'**underlay routé** entre les nœuds — c'est-à-dire le
réseau IP qui transporte les tunnels VXLAN — sans que vous écriviez une ligne de FRR.

| Fabric | Protocole | Quand l'utiliser |
|---|---|---|
| **OpenFabric** | IS-IS simplifié pour datacenters | Topologie leaf-spine, nœuds sur plusieurs segments, ECMP automatique |
| **OSPF** | OSPF classique, avec areas | Environnement où l'OSPF est déjà en place |
| **BGP** | eBGP *unnumbered*, un ASN par nœud, BFD | Fabric BGP-to-the-host, la référence en DC moderne |
| **WireGuard** | tunnels chiffrés + routage dynamique par-dessus | Nœuds répartis sur plusieurs sites / Internet |

Chaque nœud reçoit une **IP de loopback** (`dummy` interface) qui sert de VTEP.
Avantage : le tunnel VXLAN ne dépend plus d'une interface physique précise — s'il y a
deux chemins, l'ECMP les utilise.

En PVE 9.1, les fabrics sont visibles dans l'arbre des ressources de l'interface web,
avec routes, voisins et interfaces — le debug devient nettement plus agréable.

🧠 **Dans notre lab** : les 6 nœuds sont sur **un seul segment L2 plat**. L'underlay
est donc déjà trivialement fonctionnel (tout le monde se ping en direct). Une fabric
n'apporterait rien de plus, sinon de la complexité. On la présente, on ne la déploie
pas — sauf en bonus (TP 17) pour voir la mécanique WireGuard.

---

## 4. Les contrôleurs 🎛️

| Contrôleur | Rôle |
|---|---|
| **EVPN** | Le cœur : monte les sessions BGP entre nœuds (`peers`), déclare l'ASN, gère les VTEP et les route-targets. Obligatoire pour une zone EVPN. |
| **BGP** | Se greffe **par nœud** pour peerer avec un routeur externe : redistribuer les subnets EVPN vers le vrai réseau, faire de l'ECMP avec les ToR. |
| **IS-IS** | Exporte les routes EVPN vers un domaine IS-IS existant. |

Config typique du contrôleur EVPN de ce lab (`/etc/pve/sdn/controllers.cfg`) :

```ini
evpn: evpnctl
	asn 65000
	peers 172.30.30.151,172.30.30.152,172.30.30.153,172.30.30.154,172.30.30.155,172.30.30.156
```

Un seul ASN pour tout le monde ⇒ **iBGP full-mesh**. Avec 6 nœuds c'est parfaitement
raisonnable (15 sessions). Au-delà de ~10 nœuds, on passe à une fabric BGP avec
des route-reflectors ou de l'eBGP unnumbered.

---

## 5. IPAM — qui distribue les adresses ? 📇

| Plugin | Usage |
|---|---|
| **PVE (interne)** | Base intégrée dans `/etc/pve/priv/ipam.db`. Zéro dépendance. C'est notre choix. |
| **NetBox** | Source de vérité externe (URL + token API). Proxmox y réserve les IP. |
| **phpIPAM** | Idem avec phpIPAM. |

Ce que l'IPAM fait pour vous :
- attribue automatiquement une IP libre du subnet à chaque interface de VM/CT,
- garde la trace des baux (`Datacenter → SDN → IPAM`),
- alimente le DHCP et le DNS,
- évite les doublons entre six stagiaires qui déploient en même temps.

```
   Création VM → NIC sur vnet « vprod »
        │
        ├─→ IPAM cherche une IP libre dans 10.60.10.0/24
        ├─→ réserve 10.60.10.104 pour la MAC BC:24:11:xx:xx:xx
        ├─→ dnsmasq sert ce bail en DHCP
        └─→ (option) DNS crée web01.lab.local → 10.60.10.104
```

---

## 6. DHCP et DNS intégrés 🎫

### DHCP (dnsmasq)
Activable **par zone** (`dhcp: dnsmasq`). Proxmox lance une instance dnsmasq par zone
(`systemctl status dnsmasq@<zone>`), pilotée par l'IPAM. On définit un ou plusieurs
`dhcp-range` sur le subnet.

🪤 Prérequis : le paquet `dnsmasq` doit être installé **et le service système
désactivé** (`systemctl disable --now dnsmasq`), sinon conflit de ports.

### DNS
On déclare un serveur DNS (plugin **PowerDNS** aujourd'hui) au niveau de la zone,
plus un `dnszone`. Chaque IP allouée crée un enregistrement A (et un PTR si
`reversedns` est configuré). Pratique, mais optionnel : dans ce lab, on s'en passe
pour ne pas ajouter un PowerDNS à maintenir.

---

## 7. SNAT et sortie Internet — le point qui coince 🔥

C'est **le** sujet qui fait perdre des heures. Décortiquons.

### Cas zone `Simple`
SNAT est réalisé **localement** sur le nœud, vers son interface de sortie. Simple,
efficace, aucun piège. La gateway du subnet est portée par le bridge local.

### Cas zone `EVPN`
SNAT est réalisé **sur les exit nodes**. Le chemin est :

```
   VM (10.60.10.42)
      │  ① paquet vers 8.8.8.8, envoyé à la gw anycast locale
      ▼
   nœud local  (VRF zevpn)
      │  ② route par défaut apprise en BGP EVPN → pointe vers l'exit node
      │     encapsulation VXLAN
      ▼
   EXIT NODE (pve1)
      │  ③ décapsulation, sortie du VRF
      │  ④ SNAT : source 10.60.10.42 → 172.30.30.151
      ▼
   routeur 172.30.30.2 ──→ ☁
```

Et au retour, le routeur renvoie à `172.30.30.151`, qui dé-nate et réinjecte dans le
VXLAN. **Tout repose sur le fait que le paquet retour arrive sur le même nœud qui a
naté.**

### 🪤 Le piège n°1 : plusieurs exit nodes sans exit node primaire

Si vous déclarez `exitnodes pve1,pve2` sans `exitnodes-primary`, les deux annoncent la
route par défaut → **ECMP** → un flux peut sortir par pve1 et un autre par pve2.
Mais le SNAT est **stateful** (conntrack, local à chaque nœud). Un paquet retour qui
tombe sur le mauvais nœud est jeté. Symptôme : « ça marche une fois sur deux »,
« le ping passe mais pas le HTTPS ».

✅ **Solution** : `exitnodes-primary pve1`. On passe en **actif/passif** : tout sort
par pve1 ; si pve1 tombe, pve2 reprend. C'est exactement ce que la doc Proxmox
recommande dès qu'on active SNAT.

### 🪤 Le piège n°2 : le MTU

Underlay 1500 − 50 octets d'entête VXLAN = **1450 utilisables**. Si la VM émet à 1500
avec le bit DF, le paquet est jeté et l'ICMP « fragmentation needed » se perd souvent.
Symptôme signature : **le ping passe, SSH se connecte, puis gèle**, `apt update` reste
bloqué à 0 %.

✅ Trois options, par ordre de préférence :
1. Laisser la zone à MTU 1450 et donner `mtu=1` à la carte virtio de la VM
   (`mtu=1` = « hérite du bridge »). La VM se configure toute seule à 1450.
2. Monter le MTU de l'underlay physique à 1550+ (jumbo) et remettre la zone à 1500 —
   nécessite un switch coopératif : **pas notre cas**.
3. Forcer le MSS clamping. Contournement, pas une solution.

### 🪤 Le piège n°3 : l'hôte ne joint pas ses propres VM
Par défaut, l'hôte Proxmox n'a pas de route vers le VRF. Si vous voulez que le nœud
(ou un agent de monitoring dessus) puisse joindre les VM :
`exitnodes-local-routing 1`. **Activé dans ce lab** : c'est ce qui permet au poste de
joindre les VM via `pve1` (route statique `10.60.0.0/16 → 172.30.30.151`, TP 17 §8.2).

### 🪤 Le piège n°4 : FRR absent
Une zone EVPN sans `frr` + `frr-pythontools` sur **tous** les nœuds ne montera jamais
ses sessions BGP. `pvesh set /cluster/sdn` passera sans erreur visible. Vérifiez avec
`vtysh -c "show bgp l2vpn evpn summary"`.

---

### ✅ Récapitulatif : ce qu'une VM peut faire, et depuis quel nœud

C'est **la** question que tout le monde se pose au TP 17, et à laquelle les §2.5 et §7
répondent séparément sans jamais l'affirmer. Voici la synthèse.

Prenons une VM de `vprod` (`10.60.10.42`) hébergée sur **pve4**, qui n'est **pas** un
exit node (les exit nodes sont `pve1` et `pve2`, primaire `pve1`) :

| Elle veut joindre… | Verdict | Par quel mécanisme |
|---|:---:|---|
| une VM de `vprod` sur **pve1** | ✅ | **L2 sur VXLAN**. FRR annonce les couples MAC/IP en **routes EVPN type-2** : pve4 sait derrière quel VTEP joindre la MAC avant même le premier paquet — pas de flood-and-learn |
| une VM de `vpub` sur **pve6** | ✅ | **routage L3 dans le VRF** (IRB symétrique, via le `vrf-vxlan` 10000). La VM route sur **sa gateway anycast locale**, portée par pve4 : aucun trombone vers l'exit node |
| **Internet** | ✅ | route par défaut apprise en **BGP (type-5)** → réencapsulation VXLAN vers le VTEP de pve1 → décapsulation, sortie du VRF, **SNAT sur pve1**, puis `vmbr0` |
| une VM de `vdb` | ✅ | routage inter-VNet, **si** `vdb.fw` autorise le sens (cf. §8) |
| Internet **depuis `vdb`** | ❌ | `snat` non coché sur le subnet — voulu |

Et dans l'autre sens — c'est là que ça surprend :

| Qui veut joindre la VM | Verdict | Pourquoi |
|---|:---:|---|
| une autre VM de la zone | ✅ | même fabric EVPN, cf. tableau ci-dessus |
| le **shell de pve4** lui-même | ❌ **sans `exitnodes-local-routing`** | l'hôte n'a pas de route vers le VRF (cf. piège n°3) |
| un poste du LAN de la salle | ✅ **via une route statique vers un exit node** | `ip route add 10.60.0.0/16 via 172.30.30.151` sur le poste, `exitnodes-local-routing` sur la zone (TP 17 §8.2). Pour une *publication* Internet, en revanche : DNAT ou reverse-proxy (cf. §12) |

🪤 **Le piège de démonstration** : le formateur teste depuis le shell de son nœud,
`ping 10.60.10.42` échoue, et tout le monde conclut que l'EVPN est cassé — alors que
la VM sort très bien sur Internet. Testez **depuis une autre VM**, pas depuis l'hôte.

🎯 **Les deux réponses courtes**, à savoir donner sans hésiter :

1. **Oui**, deux VM du même VNet sur deux nœuds différents se parlent. C'est
   exactement ce que la zone `VXLAN` pure apportait déjà — la zone `Simple`, elle,
   ne le fait **pas** (deux îlots homonymes).
2. **Oui**, une VM sort sur Internet **sans être hébergée sur un exit node**. C'est
   la définition même d'un exit node : *« The configured nodes will announce a
   default route in the EVPN network. »* Aucune VM n'a besoin d'y être.

### La preuve, sur un nœud qui n'est PAS exit node

```bash
# Sur pve4, pve5 ou pve6
vtysh -c "show evpn vni detail"                      # le VNI L2 + le L3VNI du VRF
vtysh -c "show bgp l2vpn evpn route type macip"      # type-2 : les MAC des VM distantes
vtysh -c "show bgp l2vpn evpn route type prefix"     # type-5 : la route par défaut
ip -4 route show vrf vrf_zevpn                       # ⭐ doit contenir « default … proto bgp »
bridge fdb show | grep vxlan                         # les VTEP distants
```

Si `ip -4 route show vrf vrf_zevpn` affiche une `default` en `proto bgp` sur un nœud
qui n'est pas exit node, la question n°2 est **prouvée sur pièce**.

```bash
iptables -t nat -S POSTROUTING | grep 10.60          # → VIDE, et c'est NORMAL
```

🪤 **Ne cherchez pas de règle SNAT sur un nœud non-exit : il n'y en a pas.** Le code
de `pve-network` (`EvpnPlugin.pm`) ne pose la règle **que si le nœud courant fait
partie des gateway nodes**. Un stagiaire qui lance cette commande sur son propre nœud
la trouvera vide et conclura à tort que sa configuration est cassée. C'est sur
**l'exit node primaire** qu'il faut regarder.

---

## 8. Firewall au niveau VNet 🛡️

Depuis les versions récentes, on peut poser des règles **directement sur un VNet**,
sans toucher aux VM. Fichier : `/etc/pve/sdn/firewall/<vnet>.fw`.

**Trois choses à savoir :**

1. Seule la direction **`FORWARD`** existe (un VNet n'a pas d'« entrant » ni de
   « sortant » : c'est du trafic qui traverse). Le trafic est bidirectionnel : il faut
   **deux règles** pour autoriser un aller-retour… sauf que le suivi de connexion
   gère le retour, donc en pratique une règle par sens de *connexion*.
2. Ça ne fonctionne **qu'avec le firewall nftables** (`proxmox-firewall`).
   Le vieux `pve-firewall` iptables **ignore silencieusement** ces règles. 🪤
3. Proxmox génère automatiquement des **IPSets** utilisables dans les règles :

| IPSet | Contenu |
|---|---|
| `+sdn/<vnet>-all` | Toutes les IP du VNet (subnets + gateway) |
| `+sdn/<vnet>-gateway` | L'IP de gateway du VNet |
| `+sdn/<vnet>-no-gateway` | Toutes les IP du VNet **sauf** la gateway |
| `+sdn/<zone>-all` | Toutes les IP de la zone |

Exemple de micro-segmentation totale (les VM ne parlent qu'à leur gateway) :

```ini
[OPTIONS]
policy_forward: DROP

[RULES]
FORWARD ACCEPT -source +sdn/vprod-all -dest +sdn/vprod-gateway -log nolog
FORWARD ACCEPT -source +sdn/vprod-gateway -dest +sdn/vprod-all -log nolog
```

**Hiérarchie du firewall Proxmox :**

```
   ┌─ Datacenter  cluster.fw          IN / OUT / FORWARD  + policies globales
   │
   ├─ Nœud        host.fw             IN / OUT / FORWARD  + nftables, protections
   │
   ├─ VNet        sdn/firewall/x.fw   FORWARD uniquement   ← nftables requis
   │
   └─ VM / CT     <vmid>.fw           IN / OUT
```

Un paquet doit être accepté à **tous** les niveaux traversés. Le plus restrictif gagne.

---

## 9. Options utiles des VNets et subnets 🔧

**VNet**
| Option | Effet |
|---|---|
| `alias` | Nom lisible dans l'UI |
| `tag` | VLAN ID (zones vlan/qinq) ou VNI (zones vxlan/evpn) |
| `vlanaware` | Laisse passer les tags VLAN des VM (trunk vers la VM) |
| `isolate-ports` | **Port isolation** : les VM du VNet ne se voient pas entre elles, seulement la gateway. Micro-segmentation gratuite. |

**Subnet**
| Option | Effet |
|---|---|
| `gateway` | IP de passerelle (anycast en EVPN) |
| `snat` | Active le NAT sortant (local en `simple`, sur exit node en `evpn`) |
| `dhcp-range` | Plage(s) servie(s) par dnsmasq |
| `dnszoneprefix` | Préfixe pour l'enregistrement DNS auto |

---

## 10. Fichiers, cycle de vie et commandes 🗂️

```
/etc/pve/sdn/
├── controllers.cfg      ← contrôleurs (evpn, bgp, isis)
├── zones.cfg            ← zones
├── vnets.cfg            ← VNets
├── subnets.cfg          ← subnets
├── ipams.cfg            ← plugins IPAM
├── dns.cfg              ← plugins DNS
├── fabrics.cfg          ← fabrics (PVE 9)
├── firewall/<vnet>.fw   ← règles firewall par VNet
└── *.running.cfg        ← ⚠ la configuration RÉELLEMENT appliquée
```

🧠 **Le SDN est transactionnel** : vos modifications restent *pending* jusqu'à un
**Apply**. Tant que `zones.cfg` ≠ `zones.running.cfg`, rien n'est actif.

```bash
# Appliquer la configuration SDN (équivalent du bouton « Apply »)
pvesh set /cluster/sdn

# Voir ce qui est en attente
pvesh get /cluster/sdn --output-format json | jq

# Lister
pvesh get /cluster/sdn/zones
pvesh get /cluster/sdn/vnets
pvesh get /cluster/sdn/vnets/<vnet>/subnets
pvesh get /cluster/sdn/ipam/<ipam>/status     # baux IPAM

# Générés par le SDN
cat /etc/network/interfaces.d/sdn
cat /etc/frr/frr.conf
```

Diagnostic EVPN :
```bash
vtysh -c "show bgp l2vpn evpn summary"      # sessions BGP montées ?
vtysh -c "show bgp l2vpn evpn route"        # routes EVPN reçues
vtysh -c "show vrf"                          # VRF créés
ip -d link show type vxlan                   # tunnels VXLAN et leur VNI
bridge fdb show | grep vxlan                 # MAC apprises
ip route show vrf vrf_<zone>                 # table de routage du VRF
```

---

## 11. Pourquoi EVPN pour CE lab — le raisonnement 🎯

Contraintes :
- 6 nœuds Proxmox, **un seul LAN plat** `172.30.30.0/24`,
- une gateway `172.30.30.2` sur laquelle on n'a **aucun droit**,
- pas d'accès au switch (donc pas de trunk, pas de 802.1ad),
- il faut du L2/L3 entre nœuds, des VM qui migrent sans perdre le réseau,
  et un accès Internet depuis les VM.

Élimination :

| Option | Verdict |
|---|---|
| Zone VLAN | ❌ nécessite un trunk sur le switch |
| Zone QinQ | ❌ idem, + 802.1ad |
| Zone Simple | ❌ pas de L2 inter-nœuds : une VM migrée change de réseau |
| Zone VXLAN pure | ⚠️ L2 OK, mais **aucune gateway, aucune sortie Internet** — il faudrait bricoler une VM routeur, qui devient un SPOF non redondé |
| **Zone EVPN** | ✅ L2 + L3 + gateway anycast + exit nodes + SNAT, le tout géré par Proxmox |
| Fabric (OpenFabric/OSPF/BGP) | 🔵 inutile ici : l'underlay est déjà un LAN plat où tout le monde se voit. À garder pour du multi-segment. |
| eBGP avec le routeur amont | ❌ on n'a pas la main sur le routeur. C'est exactement pour ça que **SNAT sur exit node** existe. |

**Conclusion — la topologie retenue :**

```
   ┌──────────────────────────────────────────────────────────────┐
   │ UNDERLAY : le LAN plat 172.30.30.0/24, tel quel, non modifié │
   │            (les 6 nœuds se voient en direct = full mesh natif)│
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 │  transport VXLAN UDP/4789
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ CONTROL PLANE : iBGP EVPN, ASN 65000, full-mesh 6 peers       │
   │                 (FRRouting piloté par Proxmox)                │
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ OVERLAY : zone EVPN « zevpn », VRF VNI 10000, MTU 1450        │
   │   ├── vnet vprod  VNI 11010  10.60.10.0/24  gw .1  SNAT       │
   │   ├── vnet vpub   VNI 11020  10.60.20.0/24  gw .1  SNAT       │
   │   └── vnet vdb    VNI 11030  10.60.30.0/24  gw .1  sans SNAT  │
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ SORTIE : exitnodes = pve1, pve2                               │
   │          exitnodes-primary = pve1   ← impératif avec SNAT     │
   │          → pve1 nate derrière 172.30.30.151                   │
   │          → bascule sur pve2 si pve1 tombe                     │
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ SÉCURITÉ : policy_forward DROP au datacenter                  │
   │            + règles FORWARD par VNet (nftables + IPSets SDN)  │
   └──────────────────────────────────────────────────────────────┘
```

**Les 5 réglages qui font que ça marche** (et dont l'oubli explique 95 % des échecs) :

1. `frr` + `frr-pythontools` installés sur **tous** les nœuds
2. `exitnodes-primary` défini dès que `snat` est actif
3. MTU 1450 sur la zone **et** `mtu=1` sur les cartes virtio des VM
4. `advertise-subnets 1` si vous avez des IP secondaires ou des hôtes silencieux
5. `pvesh set /cluster/sdn` (Apply) après chaque modification

---

## 12. Ce que le SDN Proxmox ne fait pas (encore) 🚧

Pour être honnête et éviter les mauvaises surprises :

- **Pas de load-balancer** ni d'IP flottante managée (à faire avec keepalived dans une VM).
- **Pas d'ECMP avec SNAT** : c'est actif/passif, point.
- **Pas de QoS / shaping par VNet** (le shaping reste au niveau de la carte VM).
- **IPAM en tech preview** sur certains aspects : à sauvegarder avec le reste de `/etc/pve`.
- **Le firewall VNet exige nftables** — pensez à migrer, sinon vos règles sont ignorées.
- **Pas de NAT entrant (DNAT) managé** : la publication d'un service depuis Internet se
  fait à la main sur l'exit node, ou via un reverse-proxy dans une VM. (TP 09 bonus.)

---

## 13. Pour aller plus loin 📖

| Sujet | Lien |
|---|---|
| Chapitre SDN complet | <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html> |
| Wiki SDN | <https://pve.proxmox.com/wiki/Software-Defined_Network> |
| Firewall | <https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html> |
| Réseau (bridges, bonds, VLAN) | <https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysadmin_network_configuration> |
| Roadmap / nouveautés | <https://pve.proxmox.com/wiki/Roadmap> |
| FRRouting EVPN | <https://docs.frrouting.org/en/latest/evpn.html> |
