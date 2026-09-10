# TP 09 — Firewall inter-zones en *default deny* 🛡️

⏱️ **1 h 45** · Jour 2

Objectif : fermer par défaut, ouvrir explicitement. On sépare `vint` et `vdmz` avec des
règles FORWARD du Datacenter pour le routage, et des règles VNet pour la commutation,
en nftables, en s'appuyant sur les IPSets générés par le SDN.

Périmètre : standalone (TP 01–15). Les exemples dédiés sont dans
`lab/firewall/standalone/` ; les exemples historiques utilisés en cluster restent inchangés.
Même sur un seul nœud, le fichier du Datacenter s'appelle `cluster.fw`.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html>
📖 Référence maison : [`SDN.md`](SDN.md) §8

---

## 1. La matrice de flux 🎯

Le document à produire avant d'écrire la moindre règle.

| De ↓ / Vers → | INTERNAL | DMZ | Hôte / gw | Internet |
|---|:---:|:---:|:---:|:---:|
| **INTERNAL** | ✅ libre | 🟡 TCP 22/80/443, ICMP | 🟡 DHCP, DNS, ICMP | ✅ libre |
| **DMZ** | ❌ **interdit** | 🟡 TCP 80/443 | 🟡 DHCP, DNS, ICMP | 🟡 TCP 80/443, DNS UDP+TCP 53, NTP UDP 123 |
| **LAN salle 172.30.30.0/24** | 🟡 TCP 22/80/443/5432, ICMP | 🟡 TCP 22/80/443/5432, ICMP | 🟡 administration PVE | — |
| **Internet** | ❌ | ❌ (sauf DNAT explicite) | ❌ nouvelle connexion non sollicitée | — |

Légende : ✅ tout · 🟡 liste blanche · ❌ bloqué et journalisé

```
                         ☁ Internet
                              ▲
              ┌───────────────┼───── 80/443/53 ─────┐
              │ tout          │                     │
   ┌──────────┴─────┐   ┌─────┴──────────┐          │
   │   INTERNAL     │   │      DMZ       │◄─────────┘
   │ 10.10.10.0/24  │   │ 10.10.20.0/24  │
   │                │   │                │
   │  srv01  win01  │   │ alpine   rocky │
   └────────┬───────┘   └───────┬────────┘
            │  22/80/443        │
            └──────────────────►│
            ◄─────── ✖ ─────────┘
                  INTERDIT
             (et journalisé)
```

🧠 **Le principe de la DMZ** : une machine exposée est une machine *présumée compromise*.
Le seul flux DMZ → INTERNAL toléré, c'est celui qu'on ne peut pas éviter (l'accès à la
base), et encore : initié depuis l'interne quand c'est possible. Ici on choisit la
version stricte : **DMZ → INTERNAL = zéro**.

---

## 2. Activer le firewall nftables 🔧

Les règles au niveau VNet ne fonctionnent qu'avec `proxmox-firewall` (nftables).
L'ancien `pve-firewall` iptables les ignore silencieusement : c'est le piège n°1 de ce TP.

```bash
apt install -y proxmox-firewall
```

### 🪤 Avant d'aller plus loin : sur quel back-end pointe `iptables` ?

Normalement, c'est réglé depuis le [TP 01 §6](01-installation-proxmox.md) : `pve-firewall`
masqué, alternatives sur `*-nft`. On revérifie quand même, la suite du TP en dépend.

Sur Debian 13, `iptables` doit être l'alternative **`iptables-nft`**. Basculée sur
`iptables-legacy` (manipulation fréquente après le TP 07), le SDN écrit son SNAT dans
les tables legacy, invisibles depuis `nft list ruleset` : diagnostic classique et faux,
« le NAT a disparu ». Pire, les deux piles se disputent le hook NAT : les compteurs de
la règle SNAT augmentent et les paquets sortent non natés.

```bash
iptables -V                              # → v1.8.x (nf_tables) — surtout PAS (legacy)
update-alternatives --display iptables   # → doit pointer sur /usr/sbin/iptables-nft
```

Si vous lisez `(legacy)`, remettez le bon back-end et purgez les tables orphelines :

```bash
update-alternatives --set iptables  /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
for t in raw mangle nat filter; do
  iptables-legacy -t $t -F; iptables-legacy -t $t -X
  ip6tables-legacy -t $t -F; ip6tables-legacy -t $t -X
done
pvesh set /cluster/sdn          # fait ré-écrire le SNAT du SDN, cette fois via nft
nft list tables                 # « table ip nat » doit maintenant apparaître
```

🌐 `pve → Firewall → Options → nftables` : ✅

Ou en CLI, dans `/etc/pve/nodes/$(hostname)/host.fw` :

```ini
[OPTIONS]
enable: 1
nftables: 1
log_level_in: nolog
log_level_forward: info
```

```bash
systemctl status proxmox-firewall --no-pager | head -5
nft list tables
```

⚠️ **Redémarrez vos VM et CT** après le passage à nftables — et ce n'est pas une
précaution de confort.

Avec l'ancien `pve-firewall`, chaque carte en `firewall=1` est branchée derrière un
**bridge intermédiaire `fwbrXXXiY`**, et une règle `iptables -t raw -A PREROUTING -i
fwbr+ -j CT --zone 1` place son trafic dans une **zone conntrack dédiée**. Avec
`proxmox-firewall`, ces bridges n'existent plus : le guest est branché directement sur
le VNet et le filtrage se fait dans la table `bridge`.

Tant que vous n'avez pas redémarré, vous cumulez les deux topologies. Symptôme :
**le SNAT ne traduit plus le TCP** (le ping et le DNS en UDP passent, `curl` non), et
un `tcpdump -ni vmbr0` montre les paquets sortir avec l'IP privée de la VM.

```bash
ip -br link | grep fwbr      # ⭐ doit ne RIEN renvoyer une fois les guests redémarrés
```

```bash
for id in 101 102; do qm reboot $id; done
pct reboot 111 ; pct reboot 112
```

---

## 3. Les quatre étages du firewall 🏛️

```
   ┌─ ① Datacenter   /etc/pve/firewall/cluster.fw
   │     IN / OUT / FORWARD   ·   politiques globales, alias, IPSets, groupes
   │
   ├─ ② Nœud         /etc/pve/nodes/<nœud>/host.fw
   │     IN / OUT / FORWARD   ·   protection de l'hyperviseur lui-même
   │
   ├─ ③ VNet         /etc/pve/sdn/firewall/<vnet>.fw          ← nftables requis
   │     FORWARD uniquement  ·   trafic DANS le VNet, et VNet ↔ hôte
   │
   └─ ④ VM / CT      /etc/pve/firewall/<vmid>.fw
         IN / OUT              ·   la dernière ligne de défense
```

**Un paquet doit être accepté à chaque étage qu'il traverse.** Le plus restrictif gagne.

🪤 **Ordre de mise en place** : toujours écrire les règles d'autorisation **avant** de
passer une politique en DROP. Sinon vous vous coupez l'accès à `:8006` et il faut aller
brancher un clavier sur le serveur.

---

## 4. Étage ① — Datacenter : alias, IPSets, groupes 🌐

### 4.1 Alias (des noms lisibles)

`Datacenter → Firewall → Alias → Add`

| Nom | Valeur | Commentaire |
|---|---|---|
| `lan_salle` | `172.30.30.0/24` | LAN physique |
| `net_internal` | `10.10.10.0/24` | zone interne |
| `net_dmz` | `10.10.20.0/24` | zone DMZ |
| `gw_salle` | `172.30.30.2` | routeur |

```bash
pvesh create /cluster/firewall/aliases --name lan_salle   --cidr 172.30.30.0/24
pvesh create /cluster/firewall/aliases --name net_internal --cidr 10.10.10.0/24
pvesh create /cluster/firewall/aliases --name net_dmz      --cidr 10.10.20.0/24
pvesh create /cluster/firewall/aliases --name gw_salle     --cidr 172.30.30.2
```

### 4.2 IPSet `management`

Tout ce qui n'est pas dans cet IPSet n'atteint ni `:8006` ni `:22`.

```bash
pvesh create /cluster/firewall/ipset --name management --comment "Acces admin"
pvesh create /cluster/firewall/ipset/management --cidr 172.30.30.0/24 --comment "LAN salle"
pvesh get /cluster/firewall/ipset/management
```

### 4.3 Groupes de sécurité (réutilisables)

```bash
# Accès à l'administration Proxmox
pvesh create /cluster/firewall/groups --group pve-admin --comment "Acces UI/SSH PVE"
pvesh create /cluster/firewall/groups/pve-admin \
  --action ACCEPT --type in --proto tcp --dport 8006 --source +management --comment "UI"
pvesh create /cluster/firewall/groups/pve-admin \
  --action ACCEPT --type in --proto tcp --dport 22   --source +management --comment "SSH"
pvesh create /cluster/firewall/groups/pve-admin \
  --action ACCEPT --type in --proto tcp --dport 3128 --source +management --comment "SPICE"

# Un serveur web générique
pvesh create /cluster/firewall/groups --group srv-web --comment "HTTP/HTTPS"
pvesh create /cluster/firewall/groups/srv-web --action ACCEPT --type in --proto tcp --dport 80
pvesh create /cluster/firewall/groups/srv-web --action ACCEPT --type in --proto tcp --dport 443
```

### 4.4 Les politiques globales — ⚠️ à faire dans l'ordre

**D'abord** les règles d'autorisation, **ensuite** le DROP.

`Datacenter → Firewall → Rules` :

| Dir | Action | Proto | Port | Source | Commentaire |
|---|---|---|---|---|---|
| IN | ACCEPT | tcp | 8006 | `+management` | Interface web |
| IN | ACCEPT | tcp | 22 | `+management` | SSH |
| IN | ACCEPT | tcp | 5900:5999 | `+management` | noVNC |
| IN | ACCEPT | — | — | `lan_salle` | ICMP (proto `icmp`) |
| **FORWARD** | ACCEPT | tcp | 22 | `lan_salle` → `net_internal` | ⭐ SSH depuis le poste |
| **FORWARD** | ACCEPT | tcp | 80 | `lan_salle` → `net_internal` | HTTP depuis le poste |
| **FORWARD** | ACCEPT | tcp | 443 | `lan_salle` → `net_internal` | HTTPS depuis le poste |
| **FORWARD** | ACCEPT | tcp | 5432 | `lan_salle` → `net_internal` | PostgreSQL depuis le poste |
| **FORWARD** | ACCEPT | icmp | — | `lan_salle` → `net_internal` | ping depuis le poste |
| **FORWARD** | ACCEPT | … | … | `lan_salle` → `net_dmz` | les 5 mêmes flux vers la DMZ |

🧠 **Pourquoi des règles FORWARD ?** Depuis le TP 07, votre PC route vers `10.10.0.0/16`
à travers le nœud. Ce trafic n'est ni entrant ni sortant pour lui : il le traverse, et
`Forward Policy: DROP` le jette — avec vos `ssh eleve@10.10.x.y`, le `curl` vers la DMZ
et bientôt Ansible (TP 13). On rouvre donc, depuis le LAN et vers chaque réseau privé,
cinq flux : SSH, HTTP, HTTPS, PostgreSQL, ICMP. Le TP 12 ajoutera SERVICES.
Ces autorisations du trafic routé sont dans le FORWARD du Datacenter. Les fichiers
VNet autorisent aussi ces sources lorsqu'un paquet est émis localement par l'hôte
avec son IP LAN (hook OUTPUT), ce qui n'est pas le chemin routé depuis le poste.

Puis `Datacenter → Firewall → Options` :

| Option | Valeur |
|---|---|
| Firewall | ✅ |
| Input Policy | `DROP` |
| Output Policy | `ACCEPT` |
| **Forward Policy** | **`DROP`** ★ |

Fichier résultant (`/etc/pve/firewall/cluster.fw`) — modèle complet dans
`lab/firewall/standalone/cluster.fw.example` :

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
policy_forward: DROP
log_ratelimit: enable=1,rate=5/second,burst=20

[ALIASES]
lan_salle    172.30.30.0/24
net_internal 10.10.10.0/24
net_dmz      10.10.20.0/24
gw_salle     172.30.30.2

[IPSET management]
172.30.30.0/24

[RULES]
IN ACCEPT -source +management -p tcp -dport 8006 -log nolog # UI Proxmox
IN ACCEPT -source +management -p tcp -dport 22 -log nolog   # SSH
IN ACCEPT -source +management -p tcp -dport 5900:5999 -log nolog # noVNC
IN ACCEPT -source lan_salle -p icmp -log nolog

# ⭐ depuis le poste, vers les réseaux privés (via la route du TP 07)
FORWARD ACCEPT -source lan_salle -dest net_internal -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_internal -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_internal -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_internal -p tcp -dport 5432 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_internal -p icmp -log nolog
FORWARD ACCEPT -source lan_salle -dest net_dmz -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_dmz -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_dmz -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_dmz -p tcp -dport 5432 -log nolog
FORWARD ACCEPT -source lan_salle -dest net_dmz -p icmp -log nolog

# ── Services d'infrastructure portés par le nœud (gateway des VNets) ────────
# 🪤 `policy_in: DROP` s'applique AUSSI aux VM : la gateway d'un subnet SDN est
#    une IP de l'hôte. Sans ces règles, plus de DNS ni de ping vers la gateway,
#    et les règles de `vint.fw` / `vdmz.fw` n'y changent rien (§5.4).
IN ACCEPT -i vint -p udp -dport 67 -log nolog   # DHCP (la requête part de 0.0.0.0)
IN ACCEPT -i vdmz -p udp -dport 67 -log nolog
IN ACCEPT -source +sdn/vint-all -p udp -dport 53 -log nolog
IN ACCEPT -source +sdn/vint-all -p tcp -dport 53 -log nolog
IN ACCEPT -source +sdn/vint-all -p icmp -log nolog
IN ACCEPT -source +sdn/vdmz-all -p udp -dport 53 -log nolog
IN ACCEPT -source +sdn/vdmz-all -p tcp -dport 53 -log nolog
IN ACCEPT -source +sdn/vdmz-all -p icmp -log nolog
```

🧠 Les IPSets `+sdn/...` sont utilisables dans `cluster.fw` : ils sont générés dans la
table nftables globale. Des règles Datacenter qui suivent le plan d'adressage sans
recopier une seule IP.

🚨 `policy_forward: DROP` coupe tout le trafic qui transite par le nœud, y compris
l'accès Internet des VM SDN. C'est voulu, on rouvre au §5.

Vérifiez la coupure, et ce qui tient encore grâce aux règles FORWARD :

```bash
qm terminal 101           # depuis srv01
ping -c2 1.1.1.1          # → doit ÉCHOUER maintenant
```

```bash
# depuis votre PC
ssh eleve@<IP-de-srv01> hostname     # → ✅ passe toujours (FORWARD lan_salle → net_internal:22)
```

---

## 5. Étage ③ — Les règles par VNet ⭐

C'est le cœur du TP, mais **pas la totalité du filtrage**. Lisez le §5.4 avant de
conclure que « les règles VNet ne marchent pas ».

### 5.1 Les IPSets offerts par le SDN

Proxmox génère automatiquement, pour chaque VNet :

| IPSet | Contenu |
|---|---|
| `+sdn/vint-all` | toutes les IP du VNet `vint`, gateway comprise |
| `+sdn/vint-gateway` | uniquement `10.10.10.1` |
| `+sdn/vint-no-gateway` | tout le VNet **sauf** la gateway |

Aucune IP en dur dans les règles : si le plan d'adressage change, les règles suivent.

### 5.2 Règles de `vint` (réseau interne)

Le VNet ne porte que les règles des échanges commutés et avec sa gateway :
DHCP, DNS UDP/TCP, ping gateway et trafic interne libre.

```ini
# /etc/pve/sdn/firewall/vint.fw — standalone uniquement
# Commutation intra-VNet et échanges avec l'hôte.
# Le routage inter-zones / LAN / Internet est filtré dans cluster.fw, pas ici.
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# DHCP initial et réponse (le client commence avec 0.0.0.0).
FORWARD ACCEPT -p udp -dport 67:68 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p tcp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p icmp -log nolog
# Trafic émis par l'hôte avec une IP source du LAN (hook OUTPUT de l'hôte).
# Le trafic LAN routé depuis le PC reste contrôlé dans cluster.fw.
FORWARD ACCEPT -source lan_salle -dest +sdn/vint-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vint-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vint-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vint-all -p tcp -dport 5432 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vint-all -p icmp -log nolog
# Entre invités du même réseau : libre.
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-all -log nolog
```

### 5.3 Règles de `vdmz` (DMZ)

Même infrastructure, mais entre invités de la DMZ seuls HTTP et HTTPS sont ouverts.

```ini
# /etc/pve/sdn/firewall/vdmz.fw — standalone uniquement
# Commutation intra-VNet et échanges avec l'hôte.
# Le routage inter-zones / LAN / Internet est filtré dans cluster.fw, pas ici.
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# DHCP initial et réponse (le client commence avec 0.0.0.0).
FORWARD ACCEPT -p udp -dport 67:68 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p tcp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p icmp -log nolog
# Trafic émis par l'hôte avec une IP source du LAN (hook OUTPUT de l'hôte).
# Le trafic LAN routé depuis le PC reste contrôlé dans cluster.fw.
FORWARD ACCEPT -source lan_salle -dest +sdn/vdmz-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vdmz-all -p tcp -dport 5432 -log nolog
FORWARD ACCEPT -source lan_salle -dest +sdn/vdmz-all -p icmp -log nolog
# Entre invités de la DMZ : HTTP(S) uniquement.
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog
```

Le trafic **routé** `vint → vdmz` est filtré dans le FORWARD du Datacenter (§5.4),
pas par deux copies de la matrice dans les VNets. Les réponses d'une connexion
acceptée sont suivies par conntrack ; une nouvelle connexion en sens inverse reste
soumise à sa propre règle. Le firewall de la VM destination reste applicable (§6).

### Appliquer

```bash
# Fichiers d'exemple utilisables tels quels : IPSets +sdn/… et alias du Datacenter, aucune
# IP en dur (lab/firewall/standalone/README.md). Le dépôt est sur le nœud depuis le TP 08 §2.
[ -d /root/formation ] || git clone <url-du-depot> /root/formation
mkdir -p /etc/pve/sdn/firewall
cp /root/formation/lab/firewall/standalone/vint.fw.example /etc/pve/sdn/firewall/vint.fw
cp /root/formation/lab/firewall/standalone/vdmz.fw.example /etc/pve/sdn/firewall/vdmz.fw

# Aucune référence à vsrv avant sa création au TP 12.
pvesh set /cluster/sdn
systemctl reload proxmox-firewall 2>/dev/null || systemctl restart proxmox-firewall
nft list ruleset | grep -c .
```

🪤 `proxmox-firewall` **ignore silencieusement** toute règle qui référence un IPSet
inconnu. Rien à l'écran, il faut
aller le lire :

```bash
journalctl -u proxmox-firewall -n 50 --no-pager | grep -i "could not find ipset"   # → vide
```

---

### 5.4 ⚠️ Ce que les règles VNet ne filtrent PAS — à lire deux fois

Un fichier `vint.fw` ne suffit pas à autoriser le trafic routé. Voici le périmètre
de chaque zone :

> **VNet** — *Traffic passing through a SDN VNet, either from guest to guest or from
> host to guest and vice-versa.*
>
> **Host** — *Traffic going from/to a host, **or traffic that is forwarded by a
> host**. You can define rules for this zone either at the datacenter level or at the
> host level.*

Traduction opérationnelle :

| Flux | Étage qui décide | Fichier |
|---|---|---|
| VM ↔ VM **dans le même VNet** | ③ VNet | `<vnet>.fw` |
| VM ↔ **gateway / hôte** (DNS, DHCP, ping de la gw) | ③ VNet **et** ① Datacenter (`IN`) | `<vnet>.fw` + `cluster.fw` |
| VM d'un VNet → **autre VNet** (routé) | ① Datacenter / ② Nœud, direction `FORWARD` | `cluster.fw` / `host.fw` |
| VM → **Internet** (routé + SNAT) | ① Datacenter / ② Nœud, direction `FORWARD` | `cluster.fw` / `host.fw` |

Dès qu'un paquet **sort** de son VNet, il est routé par l'hôte : il ne traverse plus la
chaîne du VNet, il traverse le hook `forward`. Là, seules les règles `FORWARD` du
Datacenter et du nœud sont évaluées — puis `policy_forward: DROP`.

```
   VM 10.10.10.50 ──► 1.1.1.1
        │
        ├─ bridge vint ......... chaîne « bridge-vint »  (règles de vint.fw)
        │                        ↑ vue seulement pour vint↔vint et vint↔hôte
        │
        └─ ROUTAGE par l'hôte ─► hook « forward »
                                 ├─ host-forward     (host.fw)
                                 └─ cluster-forward  (cluster.fw)  ← ★ ici, et ici seul
                                        └─ policy_forward: DROP
```

🔬 **La preuve, sur votre nœud** — c'est aussi la meilleure technique de dépannage du
firewall nftables :

```bash
nft add table inet dbg
nft add chain inet dbg pre '{ type filter hook prerouting priority -300; }'
nft add rule  inet dbg pre ip saddr 10.10.20.101 tcp dport 443 meta nftrace set 1
nft monitor trace          # … puis lancez un curl depuis la VM, dans un autre terminal
nft delete table inet dbg  # ⚠ ne l'oubliez pas
```

Vous verrez le paquet passer de `forward` à `cluster-forward` puis `drop`, **sans
jamais visiter `bridge-vint`**. Voilà pourquoi vos règles VNet « ne servent à rien ».

#### Les règles `FORWARD` de `cluster.fw`

Elles reprennent la matrice du §1. Même logique d'ordre qu'au niveau VNet : les `DROP`
explicites **avant** les règles fourre-tout sans `-dest`. `lab/firewall/standalone/cluster.fw.example`
les contient déjà, à la suite des règles `lan_salle` du §4.4 ; si vous l'avez copié,
elles sont en place.

```ini
# ── Zone HOST : trafic ROUTÉ par le nœud (inter-VNet et sortie Internet) ─────
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p icmp -log nolog
FORWARD DROP   -source +sdn/vint-all -dest +sdn/vdmz-all -log info
FORWARD DROP   -source +sdn/vdmz-all -dest +sdn/vint-all -log warning   # 🚨 DMZ → INTERNE
FORWARD ACCEPT -source +sdn/vint-all -log nolog                          # interne → Internet
FORWARD ACCEPT -source +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p tcp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p udp -dport 123 -log nolog
```

🧠 **Alors les fichiers VNet servent-ils encore à quelque chose ?** Oui, à deux choses
que le Datacenter ne sait pas faire : filtrer le trafic **intra-VNet** (une VM de la
DMZ qui attaque sa voisine — ça ne passe jamais par le routeur, donc jamais par
`forward`), et filtrer les accès **à la gateway** elle-même. C'est de la
micro-segmentation, pas de la segmentation inter-zones. Gardez les deux : défense en
profondeur.

#### Le DHCP : la règle que personne n'écrit

Dès qu'un VNet a `policy_forward: DROP`, sa chaîne se termine par un `drop`. Or un
`DHCPDISCOVER` part de **`0.0.0.0`** vers `255.255.255.255` : **aucun IPSet SDN ne peut
le matcher**. Et la réponse de dnsmasq, de la gateway vers le guest, tombe sur le même
`drop`.

Symptôme : au premier redémarrage d'un guest, **plus aucune IP**, et dans le journal :

```
dnsmasq-dhcp: DHCPOFFER(vdmz) 10.10.20.100 bc:24:11:...
dnsmasq-dhcp: Error sending DHCP packet to 10.10.20.100: Operation not permitted
```

D'où cette ligne **en tête** des `[RULES]` de chaque fichier VNet (les exemples du dépôt
l'ont déjà) :

```ini
# DHCP : la requête vient de 0.0.0.0 (aucun IPSet ne matche) et l'OFFER repart
# de la gateway. Sans cette ligne, le drop final de la chaîne tue les deux.
FORWARD ACCEPT -p udp -dport 67:68 -log nolog
```

et, côté `cluster.fw`, la requête doit entrer sur l'interface du VNet (déjà au §4.4) :

```ini
IN ACCEPT -i vint -p udp -dport 67 -log nolog
IN ACCEPT -i vdmz -p udp -dport 67 -log nolog
```

🪤 Le piège est **différé** : tout fonctionne tant que les baux en cours sont valides.
La panne apparaît au redémarrage suivant — souvent le lendemain matin, quand plus
personne ne fait le lien avec le firewall écrit la veille.

---

## 6. Étage ④ — Les règles par VM 🔒

Défense en profondeur : même si le VNet laisse passer, la VM peut refuser.

`ct-alpine` → `Firewall → Options` : `Firewall: ✅`, `Input Policy: DROP`.
`ct-alpine` → `Firewall → Add Security Group` : `srv-web`.

```bash
cat > /etc/pve/firewall/111.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
GROUP srv-web
IN ACCEPT -source +sdn/vint-all -p tcp -dport 22 -log nolog
IN ACCEPT -source lan_salle -p tcp -dport 22 -log nolog   # depuis le poste (route du TP 07)
IN ACCEPT -p icmp -log nolog
EOF
```

🧠 Les règles FORWARD `lan_salle` (§4.4, §5) amènent le trafic du PC jusqu'à la carte de
la VM ; en `policy_in: DROP`, la VM doit encore l'accepter. D'où la ligne
`-source lan_salle` (le port 80 est couvert par `srv-web`).

Sur `srv01`, PostgreSQL est accessible depuis l'interne et le LAN salle :

```bash
cat > /etc/pve/firewall/101.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source +sdn/vint-all -p tcp -dport 5432 -log nolog
IN ACCEPT -source +sdn/vint-all -p tcp -dport 22 -log nolog
IN ACCEPT -source lan_salle -p tcp -dport 5432 -log nolog   # depuis le poste
IN ACCEPT -source lan_salle -p tcp -dport 22 -log nolog     # depuis le poste
IN ACCEPT -p icmp -log nolog
EOF
```

Et sur `win01`, RDP réservé à la zone interne :

```bash
cat > /etc/pve/firewall/102.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source lan_salle -p tcp -dport 22 -log nolog   # SSH si OpenSSH est activé
IN ACCEPT -source +sdn/vint-all -p tcp -dport 3389 -log info   # RDP
IN ACCEPT -source +sdn/vint-all -p tcp -dport 445 -log nolog   # SMB
IN ACCEPT -p icmp -log nolog
EOF
```

🧠 `-log info` sur RDP : on journalise les accès aux services d'administration. Un jour,
on vous demandera qui s'est connecté et quand.

📌 RDP reste réservé à la zone interne : depuis le PC, `win01` se pilote par
`win01 → Console`. C'est la matrice de flux, pas un oubli.

---

### SSH depuis le LAN : règle obligatoire sur chaque invité

Pour **toute VM/CT avec Input Policy DROP**, conserver dans `[RULES]`, avant un
éventuel DROP explicite :

```ini
IN ACCEPT -source lan_salle -p tcp -dport 22 -log nolog
```

Cela vaut aussi pour les nouveaux guests Terraform et PBS si leur firewall Proxmox
est activé. Pour les invités sur `vmbr0` (dont PBS), le LAN est directement connecté :
la règle FORWARD vers les VNets ne remplace pas cette autorisation invité.

Vérifier également le service SSH, la clé et le firewall **dans l'OS**. Sur Rocky avec
firewalld actif, autoriser TCP 22 depuis `172.30.30.0/24` dans la zone de la carte :

```bash
# Dans Rocky uniquement, SI firewalld est actif ; adapter à la zone de sa carte.
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.30.30.0/24" port port="22" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Sur Windows, depuis PowerShell administrateur dans noVNC :

```powershell
$sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($sshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $sshCapability.Name
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -RemoteAddress 172.30.30.0/24
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'SSH depuis LAN salle' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -RemoteAddress 172.30.30.0/24
}
```

Configurer ensuite la clé publique du compte Windows (administrateur :
`C:\ProgramData\ssh\administrators_authorized_keys`, avec les [ACL requises](https://learn.microsoft.com/fr-fr/windows-server/administration/openssh/openssh_keymanagement)), et tester
depuis le poste. RDP reste réservé à INTERNAL. Référence :
[installation OpenSSH Windows](https://learn.microsoft.com/fr-fr/windows-server/administration/openssh/openssh_install_firstuse).

### PostgreSQL : rendre les tests du TP effectivement possibles

Sur srv01, le TP 08 installe PostgreSQL mais le laisse sur loopback. Depuis SSH ou
noVNC, définir l'écoute, puis redémarrer :

```bash
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';"
sudo systemctl restart postgresql
sudo ss -lntp | grep ':5432'
sudo -u postgres psql -Atc 'SHOW hba_file;'
```

Dans le fichier indiqué, autoriser uniquement les bases/rôles nécessaires depuis
`10.10.10.0/24` et `172.30.30.0/24` avec `scram-sha-256`, puis recharger le service.
Ne pas utiliser `trust` ni ouvrir `0.0.0.0/0`. Un `nc` réussi teste TCP ; utiliser
ensuite `psql` avec un rôle et son mot de passe pour vérifier le service applicatif.

---

## 7. Tests de validation 🧪

Le script standalone se lance depuis le **poste Linux du LAN salle**, pas depuis
le nœud ni une VM. Il se connecte directement aux deux zones pour exécuter les sondes
avec la bonne IP source, sans transférer de clé privée ni utiliser agent forwarding.

```bash
bash lab/scripts/test-firewall-standalone.sh --int <ip-srv01> --dmz <ip-alpine>
```

Prérequis : route `10.10.0.0/16 via $PVE`, clés du poste autorisées sur les deux
invités, empreintes SSH vérifiées et enregistrées. `--int-user eleve` et
`--dmz-user root` sont les valeurs par défaut. Installer `netcat-openbsd`, `curl`
et `iproute2` sur les deux invités (Alpine : `apk add netcat-openbsd curl iproute2`).
nginx doit écouter sur la DMZ, PostgreSQL sur l'IP de srv01 (voir ci-dessous).

Pour le test négatif TCP 8080, lancer temporairement sur ct-alpine, dans une console
distincte : `busybox httpd -f -p 8080 -h /tmp` ; arrêter avec Ctrl+C après le test.
Le script contrôle localement ce listener avant d'interpréter un refus réseau.
L'absence de SSH, d'outil ou de listener obligatoire est une **erreur**, jamais un succès.

Pour vérifier SSH vers **chaque autre machine**, relancer depuis le poste
`ssh <compte>@<IP> hostname` (Linux, CT, Windows avec OpenSSH, PVE et PBS).
La liste d'inventaire doit être complète : deux machines sondées ne valident pas tout le parc.

### Depuis `srv01` (INTERNAL)

```bash
qm terminal 101
```

| Test | Commande | Attendu |
|---|---|---|
| Gateway | `ping -c2 10.10.10.1` | ✅ |
| Interne → interne | `ping -c2 10.10.10.<win01>` | ✅ |
| Internet | `ping -c2 1.1.1.1` | ✅ |
| DNS | `getent hosts debian.org` | ✅ |
| Interne → DMZ HTTP | `curl -sI http://10.10.20.<alpine>` | ✅ 200 |
| Interne → DMZ SSH | `nc -zv 10.10.20.<alpine> 22` | ✅ |
| Interne → RDP Windows | `nc -zv 10.10.10.<win01> 3389` | ✅ |
| Interne → DMZ autre port | `nc -zvw2 10.10.20.<alpine> 3306` | ❌ timeout |

### Depuis `ct-alpine` (DMZ)

| Test | Commande | Attendu |
|---|---|---|
| Gateway | `ping -c2 10.10.20.1` | ✅ |
| Internet HTTPS | `curl -sI https://ubuntu.com` | ✅ |
| Mise à jour | `apk update` | ✅ |
| Internet ICMP | `ping -c2 1.1.1.1` | ❌ (non autorisé) |
| **DMZ → base** | `nc -zvw2 10.10.10.<srv01> 5432` | ❌ **timeout** 🎯 |
| **DMZ → SSH interne** | `nc -zvw2 10.10.10.<srv01> 22` | ❌ **timeout** 🎯 |
| **DMZ → RDP Windows** | `nc -zvw2 10.10.10.<win01> 3389` | ❌ **timeout** 🎯 |

🧠 DMZ → INTERNAL:22 échoue alors que le FORWARD du Datacenter autorise `vint → vdmz:22` : la règle
est unidirectionnelle. Le SSH part de l'interne, jamais l'inverse.

### Lire les journaux

```bash
# Les paquets refusés, en direct
tail -f /var/log/pve-firewall.log
journalctl -f -u proxmox-firewall

# Dans l'UI : Datacenter → Firewall → Log,  ou  VNet → Firewall → Log
```

Les tentatives DMZ → INTERNAL apparaissent, taguées `warning`.

```bash
# Compteurs nftables : voir quelles règles matchent réellement
nft list ruleset | grep -B2 counter | head -40
```

---

## 8. Ouvrir un flux à la demande 🚪

Scénario : le développeur veut que `ct-alpine` (DMZ) interroge PostgreSQL sur `srv01`.

Ne pas ouvrir 5432 de la DMZ vers l'interne. Par ordre de préférence :

1. Déplacer la base derrière une **API** hébergée en interne, que la DMZ appelle en HTTPS.
2. Si c'est inévitable : ouvrir **une seule IP source vers une seule IP destination**,
   sur un seul port, et journaliser.

```ini
# Dans /etc/pve/firewall/cluster.fw — AVANT le DROP DMZ→INTERNE.
# Remplacer ces deux IP par les adresses réelles, réservées pour cet exercice.
FORWARD ACCEPT -source 10.10.20.101 -dest 10.10.10.100 -p tcp -dport 5432 -log info # INFRA-421

# Dans /etc/pve/firewall/101.fw, section [RULES] :
IN ACCEPT -source 10.10.20.101 -p tcp -dport 5432 -log info # INFRA-421
```

Sur srv01, ajouter aussi à `pg_hba.conf` une autorisation SCRAM limitée à la base,
au rôle applicatif et à `10.10.20.101/32` ; recharger PostgreSQL. Le service doit
écouter sur l'IP interne, pas seulement localhost (§6). Vérifier avec `psql` depuis
ct-alpine : une connexion TCP ne prouve pas que l'authentification fonctionne.

Cette exception change temporairement la matrice : le test « DMZ → PostgreSQL refusé »
doit alors échouer. Après l'exercice, retirer les deux règles et l'entrée pg_hba,
puis refaire les tests négatifs. Au TP 12, une exception persistante se déclare dans
Terraform avant le DROP correspondant, jamais en éditant un fichier géré par lui.

🧠 Documentez chaque exception : qui, pourquoi, jusqu'à quand. Sans ça, en deux ans,
plus personne n'ose supprimer une règle.

---

## 9. Pièges et dépannage 🔧

| Symptôme | Cause | Solution |
|---|---|---|
| Les règles VNet n'ont aucun effet | `pve-firewall` iptables actif | `nftables: 1` dans `host.fw` + `apt install proxmox-firewall` |
| Plus d'accès à `:8006` | `policy_in: DROP` sans règle d'autorisation | Console physique → `systemctl stop proxmox-firewall`, corriger `cluster.fw`, puis relancer le service |
| **Les VM n'ont plus Internet, ni accès à l'autre VNet** | Règles écrites **uniquement** au niveau VNet : elles ne couvrent pas le trafic routé | Ajouter les règles `FORWARD` dans `cluster.fw` (**§5.4**) |
| Plus de DNS ni de ping vers la gateway | `policy_in: DROP` : la gateway est une IP de l'hôte | Règles `IN ACCEPT -source +sdn/<vnet>-all` (**§4.4**) |
| **Un guest redémarré n'obtient plus d'IP** | Le `drop` final du VNet tue le `DHCPDISCOVER` (source `0.0.0.0`) et l'`OFFER` | `FORWARD ACCEPT -p udp -dport 67:68` dans le `.fw` du VNet (**§5.4**) |
| `Error sending DHCP packet … Operation not permitted` | Idem, sens hôte → guest | Idem : la plage `67:68`, pas seulement `67` |
| **`curl` bloque mais `ping` et DNS passent** | Guests encore derrière des `fwbr*` : conflit de zone conntrack, le SNAT ne traduit plus le TCP | `ip -br link \| grep fwbr` puis redémarrer les guests (**§2**) |
| « Le NAT a disparu » (`nft list ruleset` vide côté NAT) | `iptables` pointe sur `iptables-legacy` | `update-alternatives --display iptables` (**§2**) |
| Une règle est absente de `nft list ruleset` | Elle référence un IPSet inexistant (ex. `+sdn/vsrv-all` avant le TP 12) | `journalctl -u proxmox-firewall \| grep "could not find ipset"` |
| Une règle « ne marche pas » | Une règle précédente a déjà matché | Relire de haut en bas ; ajouter `-log info` pour tracer |
| Je ne sais pas **où** le paquet meurt | — | `nft monitor trace` avec une règle `meta nftrace set 1` (**§5.4**) |
| Le retour de connexion est bloqué | Croyance erronée | Le conntrack gère les retours : **une seule règle par sens de connexion** |
| Règles perdues après reboot du guest | Chaînes non recréées | Redémarrer la VM après un changement de backend firewall |

**Désactivation d'urgence** (console physique du serveur) :

```bash
pve-firewall stop
systemctl stop proxmox-firewall
# ... corriger /etc/pve/firewall/cluster.fw ...
systemctl start proxmox-firewall
```

---

## ✅ Checklist de validation

- [ ] `iptables -V` répond `(nf_tables)` et **pas** `(legacy)`
- [ ] `nftables: 1` est actif et `proxmox-firewall` tourne
- [ ] `ip -br link | grep fwbr` ne renvoie rien (guests redémarrés)
- [ ] `policy_forward: DROP` au niveau Datacenter
- [ ] `vint.fw` et `vdmz.fw` existent et sont appliqués
- [ ] `journalctl -u proxmox-firewall | grep "could not find ipset"` ne renvoie rien
- [ ] Les règles `FORWARD` de la matrice sont dans `cluster.fw`, **pas seulement** dans les `.fw` de VNet
- [ ] Un guest redémarré récupère bien une IP par DHCP
- [ ] Je sais dire quel étage filtre un flux routé, et lequel filtre un flux intra-VNet
- [ ] INTERNAL → Internet : ✅
- [ ] INTERNAL → DMZ sur 80/443/22 : ✅
- [ ] INTERNAL → DMZ sur 8080 : ❌, avec listener temporaire contrôlé
- [ ] DMZ → Internet sur 443 : ✅
- [ ] **DMZ → INTERNAL : ❌ sur tous les ports**
- [ ] Les refus DMZ → INTERNAL apparaissent dans les journaux
- [ ] J'ai toujours accès à l'interface web et au SSH du nœud
- [ ] SSH depuis `172.30.30.0/24` fonctionne vers chaque VM/CT, y compris Windows avec OpenSSH, et PBS au TP 15
- [ ] Je sais expliquer pourquoi l'ordre des règles est critique

---

## 🎁 Bonus

1. **Publier `ct-alpine` sur Internet** : ajoutez un DNAT sur l'hôte pour exposer le
   port 80 du conteneur sur `$PVE:8080`, et la règle FORWARD correspondante. Puis
   demandez-vous pourquoi Proxmox ne propose pas ça nativement (indice : où placer la
   règle dans un cluster où la VM peut migrer ?).
2. **Isolation totale** : activez `isolate-ports` sur `vdmz` **en plus** des règles.
   Vérifiez que `ct-alpine` ne voit plus `ct-rocky`, même en ARP.
3. **Générez la matrice de flux depuis les fichiers** : un script qui lit les `.fw` et
   produit un tableau markdown. Utile pour les audits.
4. Comparez `nft list ruleset` avant/après l'activation d'un VNet firewall. Repérez
   les chaînes `proxmox-firewall-forward` et les IPSets `sdn/*`.

➡️ Fin du jour 2 🎉 · Suite : [TP 10 — Cloud-image en CLI, cloud-init et clonage](10-cloudinit-cli-clonage.md)
