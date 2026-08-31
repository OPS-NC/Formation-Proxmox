# TP 17 — SDN en cluster : EVPN/VXLAN et limites du LAN plat 🌐

⏱️ **2 h** · Jour 4 · **le TP le plus dense de la formation**

Objectif : étendre le réseau sur les six nœuds, avec une gateway présente partout, du
routage entre réseaux, et un accès Internet — le tout sans toucher au switch ni au
routeur de la salle.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html>
📖 Référence maison : [`SDN.md`](SDN.md) — **relisez les §2.4, §2.5, §7 et §11 avant de commencer**
   (le récapitulatif « ce qu'une VM peut faire, et depuis quel nœud » est en fin de §7)

---

## 1. Le problème : ce qui ne marche plus 🚨

Vous êtes en cluster. Testez naïvement le SDN du TP 08, cette fois à l'échelle du
cluster.

```bash
# Sur pve1
pvesh create /cluster/sdn/zones --zone ztest --type simple \
  --nodes pve1,pve2,pve3,pve4,pve5,pve6 --ipam pve --dhcp dnsmasq
pvesh create /cluster/sdn/vnets --vnet vtest --zone ztest
pvesh create /cluster/sdn/vnets/vtest/subnets \
  --subnet 10.99.0.0/24 --type subnet --gateway 10.99.0.1 --snat 1 \
  --dhcp-range start-address=10.99.0.100,end-address=10.99.0.200
pvesh set /cluster/sdn
```

Créez une VM sur `pve1` et une sur `pve2`, toutes deux sur `vtest`. Puis :

```bash
# depuis la VM de pve1
ping 10.99.0.101      # la VM de pve2
```

💥 **Ça ne passe pas.** Et les deux VM ont peut-être même reçu la **même IP**.

### Pourquoi ?

```
        pve1                              pve2
   ┌────────────┐                    ┌────────────┐
   │  vtest     │                    │  vtest     │
   │ 10.99.0.1  │   ✖ AUCUN LIEN ✖   │ 10.99.0.1  │
   │  [VM A]    │                    │  [VM B]    │
   └────────────┘                    └────────────┘
        │                                  │
        └──── vmbr0 ──── LAN ──── vmbr0 ───┘
                (les hôtes se voient,
                 mais les bridges vtest
                 sont deux îlots séparés)
```

Une zone `Simple` crée un **bridge local, sans aucun mécanisme de transport
inter-nœuds**. Le même nom, la même IP de gateway, mais deux réseaux qui s'ignorent.
Pire : une VM migrée de `pve1` vers `pve2` change silencieusement de réseau.

```bash
# On nettoie avant d'attaquer sérieusement
pvesh delete /cluster/sdn/vnets/vtest/subnets/ztest-10.99.0.0-24
pvesh delete /cluster/sdn/vnets/vtest
pvesh delete /cluster/sdn/zones/ztest
pvesh set /cluster/sdn
```

---

## 2. Le raisonnement : pourquoi EVPN et rien d'autre 🎯

| Option | Verdict dans **notre** lab |
|---|---|
| Zone **Simple** | ❌ pas de L2 inter-nœuds — on vient de le voir |
| Zone **VLAN** | ❌ exige un trunk 802.1Q sur le switch : **pas d'accès** |
| Zone **QinQ** | ❌ exige du 802.1ad sur le switch : **pas d'accès** |
| Zone **VXLAN** pure | ⚠️ L2 OK, mais **aucune gateway, aucune sortie Internet**. Il faudrait bricoler une VM routeur → SPOF non redondé |
| **Zone EVPN** | ✅ L2 + L3 + gateway anycast + exit nodes + SNAT, géré par Proxmox |
| **Fabric** (OpenFabric/OSPF/BGP) | 🔵 inutile : notre underlay est un LAN plat où tous les nœuds se voient déjà. À garder pour du multi-segment |
| **eBGP avec le routeur amont** | ❌ on n'a pas la main dessus. **SNAT sur exit node existe précisément pour ce cas** |

👉 Le raisonnement complet, avec les schémas, est dans [`SDN.md` §11](SDN.md).

### L'architecture retenue

```
   ┌──────────────────────────────────────────────────────────────┐
   │ UNDERLAY : le LAN plat 192.168.50.0/24, non modifié           │
   │            les 6 nœuds se voient en direct = full mesh natif  │
   └──────────────────────────────────────────────────────────────┘
                                 ▲  transport VXLAN UDP/4789
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ CONTROL PLANE : iBGP EVPN, ASN 65000, full-mesh 6 peers       │
   │                 (FRRouting, généré par Proxmox)               │
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ OVERLAY : zone EVPN « zevpn », VRF VNI 10000, MTU 1450        │
   │   ├── vnet vprod  VNI 11010  10.60.10.0/24  gw .1  SNAT ✅    │
   │   ├── vnet vpub   VNI 11020  10.60.20.0/24  gw .1  SNAT ✅    │
   │   └── vnet vdb    VNI 11030  10.60.30.0/24  gw .1  SNAT ❌    │
   └──────────────────────────────────────────────────────────────┘
                                 ▲
                                 ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ SORTIE : exitnodes = pve1, pve2                               │
   │          exitnodes-primary = pve1   ← IMPÉRATIF avec SNAT     │
   └──────────────────────────────────────────────────────────────┘
```

---

## 3. Prérequis sur les 6 nœuds ⚙️

**Chaque élève, sur son nœud.** Une seule machine mal préparée fait échouer le fabric.

```bash
apt install -y frr frr-pythontools
dpkg -l | grep -E 'frr|frr-pythontools'
systemctl status frr --no-pager | head -3
```

```bash
# Le routage et le forwarding
sysctl net.ipv4.ip_forward
cat > /etc/sysctl.d/99-evpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system
```

```bash
# Le port VXLAN doit passer entre nœuds : vérifiez cluster.fw
grep -n 4789 /etc/pve/firewall/cluster.fw || echo "⚠ règle VXLAN manquante"
```

Ajoutez si nécessaire dans `/etc/pve/firewall/cluster.fw`, section `[RULES]` :

```ini
IN ACCEPT -source lan_salle -p udp -dport 4789 -log nolog # VXLAN
IN ACCEPT -source lan_salle -p tcp -dport 179  -log nolog # BGP
```

🪤 **Les deux oublis fatals** : `frr-pythontools` absent (les sessions BGP ne montent
jamais, sans message d'erreur clair) et le port 4789 bloqué (le BGP monte, les routes
arrivent, mais aucun paquet de données ne passe — le symptôme le plus déroutant).

```bash
# Test de connectivité de l'underlay depuis chaque nœud
for i in 11 12 13 14 15 16; do
  echo -n "192.168.50.$i : " ; ping -c1 -W1 192.168.50.$i >/dev/null && echo OK || echo KO
done
```

---

## 4. Le contrôleur EVPN 🎛️

**Une seule personne** (l'élève 1) crée les objets SDN : ils sont cluster-wide.

🌐 `Datacenter → SDN → Controllers → Add → EVPN`

| Champ | Valeur |
|---|---|
| ID | `evpnctl` |
| ASN # | `65000` |
| Peers | `192.168.50.11,192.168.50.12,192.168.50.13,192.168.50.14,192.168.50.15,192.168.50.16` |

```bash
pvesh create /cluster/sdn/controllers \
  --controller evpnctl --type evpn --asn 65000 \
  --peers 192.168.50.11,192.168.50.12,192.168.50.13,192.168.50.14,192.168.50.15,192.168.50.16
```

🧠 **Un seul ASN pour tout le monde ⇒ iBGP en full-mesh.** Avec 6 nœuds, cela fait 15
sessions : parfaitement raisonnable. Au-delà d'une dizaine de nœuds, on passerait à une
fabric BGP avec des route-reflectors, ou à de l'eBGP *unnumbered* — c'est précisément le
rôle des **Fabrics** de PVE 9.

---

## 5. La zone EVPN ⭐

🌐 `Datacenter → SDN → Zones → Add → EVPN`

| Champ | Valeur | Pourquoi |
|---|---|---|
| ID | `zevpn` | |
| Nodes | les 6 | |
| Controller | `evpnctl` | |
| VRF-VXLAN Tag | `10000` | VNI du VRF, distinct de ceux des VNets |
| Exit Nodes | `pve1,pve2` | les portes de sortie |
| **Primary Exit Node** | **`pve1`** | ⭐ **obligatoire avec SNAT** |
| Exit Nodes Local Routing | ✅ | pour que les hôtes joignent les VM |
| Advertise Subnets | ✅ | annonce les /24, pas seulement les /32 apprises |
| Disable ARP-ND Suppression | ❌ | (à cocher seulement si IP flottantes/VRRP) |
| MTU | **`1450`** | ⭐ 1500 − 50 octets d'entête VXLAN |
| IPAM | `pve` | |
| DHCP | `dnsmasq` | |

```bash
pvesh create /cluster/sdn/zones \
  --zone zevpn --type evpn \
  --controller evpnctl \
  --vrf-vxlan 10000 \
  --nodes pve1,pve2,pve3,pve4,pve5,pve6 \
  --exitnodes pve1,pve2 \
  --exitnodes-primary pve1 \
  --exitnodes-local-routing 1 \
  --advertise-subnets 1 \
  --mtu 1450 \
  --ipam pve --dhcp dnsmasq
```

### 🪤 Les deux réglages qui font échouer 95 % des déploiements

**① `exitnodes-primary`**

Sans lui, les deux exit nodes annoncent la route par défaut → **ECMP** → un flux sort
par `pve1`, un autre par `pve2`. Mais le SNAT est **stateful** : le suivi de connexion
est local à chaque nœud. Un paquet retour qui arrive sur le mauvais nœud est jeté.

Symptômes typiques : « le ping passe mais pas HTTPS », « ça marche une fois sur deux »,
« ça marche depuis pve1 mais pas depuis pve4 ».

Avec `exitnodes-primary pve1`, on est en **actif/passif** : tout sort par `pve1`, et
`pve2` prend le relais s'il tombe. C'est ce que recommande la documentation Proxmox
dès que SNAT est actif.

**② Le MTU**

```
   Trame VM à 1500 octets
        ▼
   [ IP hôte ][ UDP 4789 ][ VXLAN ][ ── trame VM 1500 ── ]
   └────────── 50 octets ─────────┘
        = 1550 octets sur le fil ⇒ dépasse le MTU 1500 du LAN
        ⇒ fragmenté ou jeté (bit DF)
```

Symptôme signature : **le ping passe, SSH se connecte puis gèle, `apt update` reste
bloqué à 0 %**. C'est le *PMTU black hole*. Les petits paquets passent, les gros non.

Solutions, par ordre de préférence :
1. Zone à MTU **1450** + `mtu=1` sur les cartes virtio (héritage du bridge). ⭐
2. Underlay en jumbo frames à 1550+ et zone à 1500 — **impossible ici**, on n'a pas
   accès au switch.
3. MSS clamping : un contournement, pas une solution.

---

## 6. Les trois VNets 🔌

| VNet | VNI | Subnet | Gateway | SNAT | Usage |
|---|---|---|---|---|---|
| `vprod` | 11010 | `10.60.10.0/24` | `10.60.10.1` | ✅ | Production |
| `vpub` | 11020 | `10.60.20.0/24` | `10.60.20.1` | ✅ | DMZ publique |
| `vdb` | 11030 | `10.60.30.0/24` | `10.60.30.1` | ❌ | Bases, **sans Internet** |

```bash
for v in "vprod 11010 10" "vpub 11020 20" "vdb 11030 30"; do
  set -- $v
  pvesh create /cluster/sdn/vnets --vnet $1 --zone zevpn --tag $2 --alias "EVPN $1"
done

pvesh create /cluster/sdn/vnets/vprod/subnets --subnet 10.60.10.0/24 --type subnet \
  --gateway 10.60.10.1 --snat 1 \
  --dhcp-range start-address=10.60.10.100,end-address=10.60.10.240

pvesh create /cluster/sdn/vnets/vpub/subnets --subnet 10.60.20.0/24 --type subnet \
  --gateway 10.60.20.1 --snat 1 \
  --dhcp-range start-address=10.60.20.100,end-address=10.60.20.240

pvesh create /cluster/sdn/vnets/vdb/subnets --subnet 10.60.30.0/24 --type subnet \
  --gateway 10.60.30.1 \
  --dhcp-range start-address=10.60.30.100,end-address=10.60.30.240
```

🧠 **`vdb` sans SNAT** : les VM se parlent, joignent leur gateway, sont routées vers les
autres VNets de la zone… mais **aucun paquet ne sort vers Internet**. C'est le
comportement voulu pour une base de données. Un serveur qui n'a pas besoin d'Internet
ne doit pas y avoir accès : c'est la mesure d'endiguement la plus efficace et la moins
chère qui existe.

### Appliquer

```bash
pvesh set /cluster/sdn
```

⏳ Comptez 20 à 30 secondes : Proxmox écrit `/etc/frr/frr.conf` sur les six nœuds,
recharge FRR, crée les interfaces VXLAN et le VRF.

---

## 7. Vérifier le fabric 🔬

**Sur chaque nœud**, dans cet ordre. Ne passez à l'étape suivante que si la précédente
est verte.

### 7.1 Les interfaces

```bash
ip -br link show type vxlan
ip -d link show vrf_zevpn
ip -br a | grep -E 'vprod|vpub|vdb|vrf'
```

Attendu :

```
vprod            UP    10.60.10.1/24
vpub             UP    10.60.20.1/24
vdb              UP    10.60.30.1/24
vrf_zevpn        UP
vxlan_vprod      UNKNOWN
```

### 7.2 La gateway anycast — la démonstration qui impressionne 🎩

```bash
# À exécuter sur pve1, pve3, pve5…
ip -br a show vprod
ip link show vprod | grep ether
```

🧠 **La même IP `10.60.10.1` et la même adresse MAC sur les six nœuds.** Une VM parle
toujours à « sa » gateway, qui est en réalité le nœud sur lequel elle tourne. Après
une migration à chaud, la VM ne s'aperçoit de rien : même IP, même MAC, aucun ARP à
refaire, **zéro paquet perdu**.

### 7.3 Les sessions BGP

```bash
vtysh -c "show bgp l2vpn evpn summary"
```

Attendu : **5 voisins en état `Established`** (les 5 autres nœuds).

```
Neighbor        V   AS  MsgRcvd  MsgSent  Up/Down  State/PfxRcd
192.168.50.11   4 65000     142      139  00:05:12            8
192.168.50.12   4 65000     140      138  00:05:10            8
...
```

🪤 Un voisin en `Active` ou `Connect` = la session ne monte pas. Vérifiez :
`frr-pythontools` installé, port 179 ouvert, IP correcte dans `peers`.

### 7.4 Les routes EVPN

```bash
vtysh -c "show bgp l2vpn evpn route" | head -40
vtysh -c "show bgp l2vpn evpn route type prefix" | head -20   # routes type-5 (/24)
vtysh -c "show ip route vrf vrf_zevpn"
```

Vous devez voir :
- des **routes type-2** : les MAC/IP des VM apprises sur les autres nœuds,
- des **routes type-5** : les subnets `10.60.x.0/24` (grâce à `advertise-subnets`),
- une **route par défaut `0.0.0.0/0`** pointant vers l'exit node.

### 7.5 Sur l'exit node uniquement

```bash
# Sur pve1
ip route show vrf vrf_zevpn
iptables -t nat -S | grep -i 10.60          # ou : nft list ruleset | grep -A5 masquerade
```

Vous devez trouver les règles SNAT pour `10.60.10.0/24` et `10.60.20.0/24` —
mais **pas** pour `10.60.30.0/24`.

### 7.6 Sur un nœud qui n'est **pas** exit node ⭐

C'est le contrôle le plus instructif du TP, et celui que personne ne pense à faire.

```bash
# Sur pve3, pve4, pve5 ou pve6 — surtout PAS sur pve1/pve2
vtysh -c "show evpn vni detail" | head -30           # le VNI L2 + le L3VNI du VRF
vtysh -c "show bgp l2vpn evpn route type macip" | head -20   # type-2 : MAC des VM distantes
vtysh -c "show bgp l2vpn evpn route type prefix" | head -20  # type-5 : les /24 + la default
ip -4 route show vrf vrf_zevpn
bridge fdb show | grep vxlan | head
```

Ce que vous devez voir dans `ip -4 route show vrf vrf_zevpn` :

```
default nhid 21 via 10.60.10.1 dev vrfbr_zevpn proto bgp metric 20
10.60.10.0/24 dev vprod proto kernel scope link src 10.60.10.1
10.60.20.0/24 dev vpub  proto kernel scope link src 10.60.20.1
```

🎯 **Cette ligne `default … proto bgp` est la preuve** que votre nœud, qui n'est pas
exit node, sait quand même router vers Internet : il a appris la route par défaut de
`pve1` en BGP EVPN. **Vos VM sortiront**, sans être hébergées sur un exit node. C'est
toute la raison d'être de l'option `exitnodes`.

Et maintenant le contrôle qui déroute :

```bash
iptables -t nat -S POSTROUTING | grep 10.60      # → AUCUNE SORTIE
```

🪤 **C'est normal, et ce n'est pas une panne.** Le code de Proxmox
(`PVE/Network/SDN/Zones/EvpnPlugin.pm`) ne pose la règle SNAT **que si le nœud courant
figure dans les exit nodes**. Sur pve4, il n'y a rien à voir : le NAT se fait sur
`pve1`, après décapsulation du VXLAN. Beaucoup de gens perdent une heure ici.

```
   VM sur pve4 ──VXLAN──► pve1 ──décapsule──► sort du VRF ──SNAT──► vmbr0 ──► ☁
       │                    │
   pas de SNAT ici    le SNAT est ICI, et seulement ici
```

📌 **Le pendant côté hôte** : depuis le shell de pve4, `ping 10.60.10.<vm>` échoue si
`exitnodes-local-routing` n'est pas activé — l'hôte n'a pas de route vers le VRF. Ne
concluez pas trop vite : **testez depuis une VM, pas depuis l'hyperviseur.**

### 7.7 Le script de diagnostic

```bash
bash /root/formation/lab/scripts/evpn-diag.sh
```

Il enchaîne tous les contrôles ci-dessus et signale ce qui cloche.

---

## 8. Déployer et tester 🚀

Chaque élève déploie **sur son nœud**, dans les VNets partagés.

```bash
N=3
qm clone ${N}90 ${N}60 --name evpn-prod-e$N --pool eleve$N --full 1
qm set ${N}60 --net0 virtio,bridge=vprod,firewall=1,mtu=1 --ipconfig0 ip=dhcp
qm set ${N}60 --tags "evpn,prod,eleve$N"
qm start ${N}60

qm clone ${N}91 ${N}61 --name evpn-pub-e$N --pool eleve$N --full 1
qm set ${N}61 --net0 virtio,bridge=vpub,firewall=1,mtu=1 --ipconfig0 ip=dhcp
qm set ${N}61 --tags "evpn,pub,eleve$N"
qm start ${N}61
```

🪤 **`--full 1` n'est pas une coquetterie ici.** Sur un template, `qm clone` fait un
**clone lié** par défaut. Or un clone lié sur stockage local **ne peut pas migrer** :
Proxmox refuse avec `can't migrate 'local-lvm:base-390-disk-0/vm-360-disk-0' as it's
a clone of 'base-390-disk-0'` — l'image de base n'existe pas sur le nœud cible.
Comme on va justement démontrer la migration au §9, on paie les 30 secondes de copie.

Le tableau du [TP 10 §5](10-cloudinit-cli-clonage.md) le disait déjà : *« ❌ pas de
migration vers un autre stockage »*. C'est le moment où ça se paie.

⚠️ **`mtu=1` n'est pas optionnel ici.** C'est ce qui fait hériter le MTU 1450 du VNet.
Oubliez-le et vous passerez vingt minutes à chercher pourquoi `apt` gèle.

### 8.1 L'IPAM à l'échelle du cluster

```bash
pvesh get /cluster/sdn/ipam/pve/status --output-format json | jq -r \
  '.[] | select(.subnet != null) | "\(.ip)\t\(.vmid // "-")\t\(.hostname // "-")"' | sort -V
```

🧠 **Six élèves déploient en même temps, personne n'obtient la même IP.** L'IPAM est
dans `/etc/pve`, donc clusterisé, donc atomique. C'est exactement le service qu'on
bricolait avec un tableur il y a dix ans.

### 8.2 Les tests qui comptent

Depuis votre VM `evpn-prod-eN` :

| # | Test | Commande | Attendu |
|---|---|---|---|
| 1 | Gateway locale | `ping -c2 10.60.10.1` | ✅ |
| 2 | **VM d'un autre élève, autre nœud** | `ping -c2 10.60.10.<autre>` | ✅ 🎯 |
| 3 | **Routage inter-VNet** | `ping -c2 10.60.20.<vpub>` | ✅ 🎯 |
| 4 | Internet | `ping -c2 9.9.9.9` | ✅ |
| 5 | **MTU — juste en dessous** | `ping -M do -s 1422 -c2 9.9.9.9` | ✅ |
| 6 | **MTU — juste au-dessus** | `ping -M do -s 1423 -c2 9.9.9.9` | ❌ *frag needed* 🎯 |
| 7 | **Gros transfert** | `curl -o /dev/null https://cdimage.debian.org/.../SHA256SUMS` | ✅ |
| 8 | `apt update` complet | `sudo apt update && sudo apt install -y htop` | ✅ |

Depuis une VM de `vdb` :

| # | Test | Attendu |
|---|---|---|
| 9 | `ping 10.60.30.1` | ✅ |
| 10 | `ping 10.60.10.<prod>` | ✅ routage inter-VNet |
| 11 | **`ping 9.9.9.9`** | ❌ **pas de SNAT, c'est voulu** 🎯 |


🧠 **Pourquoi ces deux tailles ?** `ping -s N` fixe la charge utile ; il faut ajouter
**28 octets** (20 IP + 8 ICMP) pour obtenir la taille du paquet :

| `-s` | Paquet | Verdict avec MTU 1450 | Ce que ça prouve |
|---|---|---|---|
| `1422` | 1450 | ✅ passe | le chemin accepte bien 1450 |
| `1423` | 1451 | ❌ *frag needed* | 🎯 **la limite est exactement à 1450** |
| `1472` | 1500 | ❌ | la limite est sous 1500 (peu informatif) |
| `1473` | 1501 | ❌ | échouerait même sans VXLAN — **ne prouve rien** |

⚠️ Le couple `1422 / 1423` est le seul qui **encadre** le MTU de la zone. `1473` est
un test paresseux : il échoue sur n'importe quel réseau Ethernet standard.

🧠 **Les tests 5 à 8 sont les plus importants.** Le ping seul ne prouve rien : il tient
dans 64 octets. C'est le transfert massif qui révèle un problème de MTU.

### 8.3 Par où sort le trafic ?

Sur `pve1` (l'exit node primaire), pendant qu'une VM d'un **autre** nœud télécharge :

```bash
tcpdump -ni vmbr0 -c 20 'host 9.9.9.9 or port 443'
conntrack -L 2>/dev/null | grep 10.60 | head
watch -n1 'iptables -t nat -L -n -v | grep -A2 10.60'
```

Vous voyez le trafic d'une VM de `pve4` sortir par `pve1`, naté derrière
`192.168.50.11`. **C'est la démonstration visuelle de l'exit node.**

Et le chemin aller :

```bash
# sur pve4
tcpdump -ni vmbr0 -c 10 'udp port 4789'      # le trafic VXLAN vers pve1
```

---

## 9. La migration à chaud : le moment de vérité 🎯

C'est **la** démonstration qui justifie tout le TP.

```bash
# Depuis votre PC, un ping continu vers la VM
ping 10.60.10.<votre-vm>
```

Pendant ce temps, sur le nœud :

```bash
qm migrate ${N}60 pve5 --online --with-local-disks
```

Observez le ping. ✅ **Zéro ou un paquet perdu.** La VM a changé de machine physique,
et son réseau n'a pas bougé d'un millimètre.

```bash
qm config ${N}60 | grep -E 'net0'
ssh -J root@192.168.50.11 eleve@10.60.10.<ip> 'ip -br a; ip route; arp -n'
```

L'entrée ARP de la gateway est **identique** avant et après. C'est l'anycast.

🧠 Comparez mentalement avec la zone `Simple` du §1 : la même migration aurait fait
atterrir la VM dans un réseau homonyme mais totalement différent, sans qu'elle s'en
aperçoive — et sans qu'elle puisse joindre quoi que ce soit.

---

## 10. Le firewall en cluster 🛡️

Les règles VNet du TP 09 s'appliquent maintenant sur les six nœuds, écrites une fois.

`/etc/pve/sdn/firewall/vdb.fw` :

```ini
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# Infra
FORWARD ACCEPT -source +sdn/vdb-all -dest +sdn/vdb-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdb-all -dest +sdn/vdb-gateway -p icmp -log nolog

# Entre bases
FORWARD ACCEPT -source +sdn/vdb-all -dest +sdn/vdb-all -log nolog

# La prod peut interroger les bases
FORWARD ACCEPT -source +sdn/vprod-all -dest +sdn/vdb-all -p tcp -dport 5432 -log nolog
FORWARD ACCEPT -source +sdn/vprod-all -dest +sdn/vdb-all -p tcp -dport 3306 -log nolog

# Les bases initient vers la prod : supervision, sauvegarde, diagnostic
# ⚠ SANS CES LIGNES, le test #10 du §8.2 échoue : policy_forward est en DROP et
#   aucune règle n'a « vdb » pour SOURCE. Le conntrack ne couvre que le paquet
#   RETOUR d'une connexion déjà acceptée, jamais le sens initial.
FORWARD ACCEPT -source +sdn/vdb-all -dest +sdn/vprod-all -p icmp -log nolog
FORWARD ACCEPT -source +sdn/vdb-all -dest +sdn/vprod-all -p tcp -dport 22 -log info

# 🚨 La DMZ publique n'approche pas des bases
FORWARD DROP -source +sdn/vpub-all -dest +sdn/vdb-all -log warning
```

🧠 **Relisez le test #10 du §8.2** (« depuis `vdb` : `ping 10.60.10.<prod>` ✅ »).
Sans les deux lignes `-source +sdn/vdb-all`, il devient ❌ dès que vous posez ce
fichier. C'est le piège déjà rencontré aux TP 09 et 12 : **une règle FORWARD est
unidirectionnelle**, et le firewall du VNet **source** compte autant que celui du
VNet destination.

🪤 **Un VNet sans fichier `.fw` n'est pas filtré du tout.** `vprod` n'a pas de règles
ici : tout y passe, donc rien à ajouter de son côté. Posez-vous la question à chaque
fois — *« ce VNet est-il permissif par choix, ou par oubli ? »*

`/etc/pve/sdn/firewall/vpub.fw` :

```ini
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
FORWARD ACCEPT -source +sdn/vpub-all -dest +sdn/vpub-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vpub-all -dest +sdn/vpub-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vpub-all -dest +sdn/vpub-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vprod-all -dest +sdn/vpub-all -log nolog
FORWARD DROP   -source +sdn/vpub-all -dest +sdn/vprod-all -log warning
FORWARD DROP   -source +sdn/vpub-all -dest +sdn/vdb-all -log warning
FORWARD ACCEPT -source +sdn/vpub-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vpub-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vpub-all -p udp -dport 53 -log nolog
```

```bash
pvesh set /cluster/sdn
```

🎯 **Testez depuis un nœud, puis depuis un autre.** Les règles s'appliquent partout,
identiquement. Vous venez d'écrire une politique de sécurité pour six hyperviseurs
dans deux fichiers texte.

---

## 11. Tester la bascule d'exit node 🔥

Démonstration de résilience — **avec l'accord du formateur**, puisque `pve1` héberge
peut-être des services de la salle.

```bash
# Depuis une VM d'un nœud quelconque, un ping continu vers Internet
ping 9.9.9.9
```

Sur `pve1` :

```bash
ifdown vmbr0     # ⚠ vous perdez l'accès au nœud ; console physique requise
# ou, moins brutal :  systemctl stop frr
```

Observez :
- quelques secondes d'interruption (convergence BGP),
- puis le ping repart : `pve2` a pris le relais.

```bash
# sur pve2
vtysh -c "show ip route vrf vrf_zevpn 0.0.0.0/0"
iptables -t nat -S | grep 10.60
```

Rétablissez :

```bash
systemctl start frr     # ou ifup vmbr0 depuis la console
```

🧠 **Actif/passif, pas actif/actif.** Il y a une coupure. C'est le prix du SNAT
stateful. Pour faire mieux, il faudrait de l'ECMP sans NAT — donc des subnets routables
annoncés au routeur amont en BGP — donc l'accès à ce routeur. **Retour à la contrainte
initiale du lab.** C'est la bonne réponse à donner en soutenance : « on a fait le
meilleur choix possible compte tenu de la contrainte, et voici ce qu'on ferait avec le
contrôle du réseau physique ».

---

## 12. Les limites, honnêtement 🚧

| Limite | Origine | Ce qu'on ferait avec l'accès au réseau physique |
|---|---|---|
| Coupure lors de la bascule d'exit node | SNAT stateful | eBGP avec les ToR, subnets routables, ECMP → bascule sans coupure |
| MTU réduit à 1450 | overhead VXLAN | Jumbo frames 9000 sur l'underlay → MTU 8950 dans les VM |
| Corosync sur le même LAN que tout le reste | un seul segment | VLAN dédié pour Corosync, un autre pour le stockage |
| Tout le trafic sortant transite par un nœud | pas de routeur coopératif | Anycast gateway annoncée en BGP depuis tous les nœuds |
| Pas de DNAT managé pour publier un service | absent du SDN Proxmox | HAProxy/nginx en VM, ou du DNAT sur l'exit node |
| iBGP full-mesh | simple mais en O(n²) | Fabric BGP + route-reflectors, ou eBGP unnumbered |

🧠 **Savoir énoncer les limites de son architecture vaut mieux que de prétendre qu'elle
est parfaite.** C'est ce qui distingue un ingénieur d'un exécutant.

---

## 13. Dépannage 🔧

| Symptôme | Cause probable | Vérification |
|---|---|---|
| Sessions BGP en `Active` | `frr-pythontools` absent, port 179 filtré | `vtysh -c "show bgp summary"` ; `dpkg -l frr-pythontools` |
| BGP OK mais VM isolées | UDP 4789 bloqué | `tcpdump -ni vmbr0 udp port 4789` sur deux nœuds |
| Ping OK, SSH gèle, `apt` bloqué | **MTU** | `ping -M do -s 1422` ✅ / `-s 1423` ❌ ; `mtu=1` sur la VM |
| Pas d'Internet du tout | SNAT ou exit node | Sur l'exit node : `iptables -t nat -S \| grep 10.60` |
| Internet intermittent | `exitnodes-primary` non défini | `cat /etc/pve/sdn/zones.cfg` |
| L'hôte ne ping pas ses VM | `exitnodes-local-routing` | l'activer sur la zone |
| VM silencieuse injoignable | routes /32 non apprises | activer `advertise-subnets` |
| Rien n'a changé après modification | Apply oublié | `pvesh set /cluster/sdn` |
| Le VNet n'existe pas sur un nœud | nœud absent de la liste `nodes` | `pvesh get /cluster/sdn/zones/zevpn` |

Commandes de diagnostic à connaître par cœur :

```bash
vtysh -c "show bgp l2vpn evpn summary"       # les sessions
vtysh -c "show bgp l2vpn evpn route"         # les routes reçues
vtysh -c "show evpn vni detail"              # les VNI et leurs VTEP
vtysh -c "show evpn mac vni all"             # les MAC apprises
ip -d link show type vxlan                   # les tunnels
bridge fdb show | grep vxlan                 # la table de commutation
ip route show vrf vrf_zevpn                  # la table du VRF
cat /etc/frr/frr.conf                        # ce que Proxmox a généré
journalctl -u frr -n 50
```

---

## ✅ Checklist de validation

- [ ] `frr` + `frr-pythontools` sur les 6 nœuds
- [ ] `vtysh -c "show bgp l2vpn evpn summary"` : 5 voisins `Established` partout
- [ ] `ip -br a show vprod` : **même IP et même MAC** sur tous les nœuds
- [ ] Deux VM sur deux **nœuds différents**, même VNet, se pingent 🎯
- [ ] Le routage inter-VNet fonctionne (`vprod` ↔ `vpub`)
- [ ] Les VM de `vprod`/`vpub` accèdent à Internet
- [ ] Les VM de `vdb` **n'ont pas** Internet, mais joignent `vprod` (règles dans les DEUX sens)
- [ ] `ping -M do -s 1422` passe, `-s 1423` échoue proprement (la limite est bien à 1450)
- [ ] Un `apt install` complet réussit dans une VM (le vrai test du MTU)
- [ ] Le trafic sortant transite bien par `pve1` (`tcpdump` à l'appui)
- [ ] Sur un nœud **non-exit**, `ip -4 route show vrf vrf_zevpn` montre une `default … proto bgp`
- [ ] Sur ce même nœud, `iptables -t nat -S POSTROUTING | grep 10.60` est **vide**, et je sais pourquoi
- [ ] Une migration à chaud ne coûte **aucun** paquet perdu
- [ ] Les règles de firewall VNet s'appliquent sur les 6 nœuds
- [ ] Je sais expliquer pourquoi `exitnodes-primary` est obligatoire avec SNAT
- [ ] Je sais énoncer trois limites de cette architecture

---

## 🎁 Bonus

1. **Comparer avec une zone VXLAN pure** : créez `zvx` (type VXLAN, peers = les 6
   nœuds), un VNet, et deux VM sur deux nœuds. Le L2 fonctionne, elles se pingent.
   Puis essayez de joindre Internet. Constatez qu'il n'y a **pas de gateway du tout**.
   Vous venez de comprendre ce que le « E » de EVPN apporte.
2. **Une fabric WireGuard** : `Datacenter → SDN → Fabrics → Add → WireGuard`. Montez un
   underlay chiffré entre deux nœuds et déplacez-y le VTEP. C'est ainsi qu'on étend un
   cluster entre deux sites via Internet.
3. **Publier un service** : sur `pve1`, un DNAT `192.168.50.11:8443 → 10.60.20.x:443`,
   plus la règle FORWARD. Puis réfléchissez : que se passe-t-il si `pve1` tombe ?
   Comment feriez-vous propre ? (Indice : HAProxy + IP virtuelle keepalived.)
4. **`rt-import`** : lisez la documentation de cette option et expliquez dans quel cas
   elle sert (interconnexion avec le fabric EVPN d'un datacenter existant).
5. **Mesurer le coût de l'encapsulation** : `iperf3` entre deux VM du même VNet sur deux
   nœuds, puis entre les deux hôtes en direct sur `vmbr0`. Quel est le surcoût VXLAN ?

➡️ Suite : [TP 18 — Cluster Ceph intégré à Proxmox](18-ceph-cluster.md) 🐙
