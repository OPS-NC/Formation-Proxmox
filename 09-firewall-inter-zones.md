# TP 09 — Firewall inter-zones en *default deny* 🛡️

⏱️ **1 h 45** · Jour 2

Objectif : fermer par défaut, ouvrir explicitement. On sépare `vint` et `vdmz` avec des
règles au niveau VNet, en nftables, en s'appuyant sur les IPSets générés par le SDN.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html>
📖 Référence maison : [`SDN.md`](SDN.md) §8

---

## 1. La matrice de flux 🎯

C'est **le document** à produire avant d'écrire la moindre règle. Toujours.

| De ↓ / Vers → | INTERNAL | DMZ | Hôte / gw | Internet |
|---|:---:|:---:|:---:|:---:|
| **INTERNAL** | ✅ libre | 🟡 22, 80, 443 | 🟡 DNS, ICMP | ✅ libre |
| **DMZ** | ❌ **interdit** | 🟡 80, 443 | 🟡 DNS, ICMP | 🟡 80, 443, 53 |
| **Internet** | ❌ | ❌ (sauf DNAT explicite) | 🟡 8006, 22 | — |

Légende : ✅ tout · 🟡 liste blanche · ❌ bloqué et journalisé

```
                         ☁ Internet
                              ▲
              ┌───────────────┼───── 80/443/53 ─────┐
              │ tout          │                     │
   ┌──────────┴─────┐   ┌─────┴──────────┐          │
   │   INTERNAL     │   │      DMZ       │◄─────────┘
   │  10.N.10.0/24  │   │  10.N.20.0/24  │
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

Les règles au niveau VNet **ne fonctionnent qu'avec `proxmox-firewall` (nftables)**.
Le vieux `pve-firewall` iptables les ignore **silencieusement** — c'est le piège n°1 de
ce TP.

```bash
apt install -y proxmox-firewall
```

### 🪤 Avant d'aller plus loin : sur quel back-end pointe `iptables` ?

Sur Debian 13, la commande `iptables` doit être l'alternative **`iptables-nft`**. Si
quelqu'un l'a basculée sur `iptables-legacy` — c'est une manipulation qu'on croise
souvent après le TP 07 — le SDN écrira son SNAT dans les tables **legacy**. Elles sont
invisibles depuis `nft list ruleset`, d'où le diagnostic classique et faux : « le NAT a
disparu ». Pire, les deux piles se disputent le hook NAT : les compteurs de la règle
SNAT augmentent, et les paquets **sortent quand même non natés**.

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

🌐 `pveN → Firewall → Options → nftables` : ✅

Ou en CLI, dans `/etc/pve/nodes/pveN/host.fw` :

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
N=3     # ⚠ VOTRE numéro d'élève
for id in ${N}01 ${N}02; do qm reboot $id; done
pct reboot ${N}11 ; pct reboot ${N}12
```

---

## 3. Les quatre étages du firewall 🏛️

```
   ┌─ ① Datacenter   /etc/pve/firewall/cluster.fw
   │     IN / OUT / FORWARD   ·   politiques globales, alias, IPSets, groupes
   │
   ├─ ② Nœud         /etc/pve/nodes/pveN/host.fw
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
| `net_internal` | `10.N.10.0/24` | zone interne |
| `net_dmz` | `10.N.20.0/24` | zone DMZ |
| `gw_salle` | `172.30.30.2` | routeur |
| `pc_eleve` | l'IP de **votre poste** (`hostname -I`) | mon poste |

```bash
N=3
pvesh create /cluster/firewall/aliases --name lan_salle   --cidr 172.30.30.0/24
pvesh create /cluster/firewall/aliases --name net_internal --cidr 10.$N.10.0/24
pvesh create /cluster/firewall/aliases --name net_dmz      --cidr 10.$N.20.0/24
pvesh create /cluster/firewall/aliases --name gw_salle     --cidr 172.30.30.2
```

### 4.2 IPSet `management`

C'est **la** protection de votre accès administrateur. Tout ce qui n'est pas dedans
n'atteindra jamais `:8006` ni `:22`.

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
| IN | ACCEPT | udp | 5405:5412 | `lan_salle` | Corosync (jour 4) |
| IN | ACCEPT | — | — | `lan_salle` | ICMP (proto `icmp`) |

Puis `Datacenter → Firewall → Options` :

| Option | Valeur |
|---|---|
| Firewall | ✅ |
| Input Policy | `DROP` |
| Output Policy | `ACCEPT` |
| **Forward Policy** | **`DROP`** ★ |

Fichier résultant (`/etc/pve/firewall/cluster.fw`) — modèle complet dans
`lab/firewall/cluster.fw.example` :

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
policy_forward: DROP
log_ratelimit: enable=1,rate=5/second,burst=20

[ALIASES]
lan_salle    172.30.30.0/24
net_internal 10.3.10.0/24
net_dmz      10.3.20.0/24
gw_salle     172.30.30.2

[IPSET management]
172.30.30.0/24

[RULES]
IN ACCEPT -source +management -p tcp -dport 8006 -log nolog # UI Proxmox
IN ACCEPT -source +management -p tcp -dport 22 -log nolog   # SSH
IN ACCEPT -source +management -p tcp -dport 5900:5999 -log nolog # noVNC
IN ACCEPT -source lan_salle -p udp -dport 5405:5412 -log nolog   # Corosync
IN ACCEPT -source lan_salle -p icmp -log nolog

# ── Services d'infrastructure portés par le nœud (gateway des VNets) ────────
# 🪤 `policy_in: DROP` s'applique AUSSI aux VM : la gateway d'un subnet SDN, c'est
#    une IP de l'hôte. Sans ces règles, plus de DNS ni de ping vers la gateway —
#    et les règles de `vint.fw` / `vdmz.fw` n'y changent rien (voir §5.4).
IN ACCEPT -source +sdn/vint-all -p udp -dport 53 -log nolog
IN ACCEPT -source +sdn/vint-all -p tcp -dport 53 -log nolog
IN ACCEPT -source +sdn/vint-all -p icmp -log nolog
IN ACCEPT -source +sdn/vdmz-all -p udp -dport 53 -log nolog
IN ACCEPT -source +sdn/vdmz-all -p tcp -dport 53 -log nolog
IN ACCEPT -source +sdn/vdmz-all -p icmp -log nolog
```

🧠 **Oui, les IPSets `+sdn/...` sont utilisables dans `cluster.fw`.** Ils sont générés
dans la table nftables globale, pas dans un espace de noms réservé aux fichiers de
VNet. C'est ce qui permet d'écrire au niveau Datacenter des règles qui suivent
automatiquement votre plan d'adressage.

🚨 **`policy_forward: DROP` coupe TOUT le trafic transitant par le nœud** — y compris
l'accès Internet de vos VM SDN. C'est voulu : on va rouvrir chirurgicalement. Prévenez
que « plus rien ne marche » pendant les cinq prochaines minutes, c'est normal.

Vérifiez la casse :

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm terminal ${N}01        # depuis srv01
ping -c2 1.1.1.1       # → doit ÉCHOUER maintenant
```

---

## 5. Étage ③ — Les règles par VNet ⭐

C'est le cœur du TP… mais **pas la totalité du filtrage**, et c'est le point qui fait
perdre le plus de temps. Lisez le §5.4 avant de conclure que « les règles VNet ne
marchent pas ».

### 5.1 Les IPSets offerts par le SDN

Proxmox génère automatiquement, pour chaque VNet :

| IPSet | Contenu |
|---|---|
| `+sdn/vint-all` | toutes les IP du VNet `vint`, gateway comprise |
| `+sdn/vint-gateway` | uniquement `10.N.10.1` |
| `+sdn/vint-no-gateway` | tout le VNet **sauf** la gateway |
| `+sdn/zint-all` | toutes les IP de la zone `zint` |

Énorme avantage : **vos règles ne contiennent aucune IP en dur**. Si vous changez de
plan d'adressage, les règles suivent.

### 5.2 Règles de `vint` (réseau interne)

🌐 `Datacenter → SDN → VNets → vint → Firewall`

Ou directement le fichier `/etc/pve/sdn/firewall/vint.fw` :

```ini
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# --- Services d'infrastructure -----------------------------------------------
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p udp -dport 53 -log nolog # DNS
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p tcp -dport 53 -log nolog # DNS TCP
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p icmp -log nolog

# --- Interne vers interne : libre --------------------------------------------
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-all -log nolog

# --- Interne vers DMZ : liste blanche ----------------------------------------
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 22 -log nolog  # admin SSH
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p icmp -log nolog

# --- Interne vers Internet : tout --------------------------------------------
FORWARD ACCEPT -source +sdn/vint-all -log nolog

# --- Tout le reste tombe dans policy_forward: DROP ---------------------------
```

🧠 **Pourquoi la dernière règle « vers Internet » suffit-elle ?** Elle n'a pas de
`-dest`, donc elle accepte tout ce qui vient de `vint`… y compris vers `vdmz`.
Les règles précédentes deviendraient inutiles ! 🪤

**Corrigeons** : il faut refuser explicitement `vint → vdmz` **avant** la règle
fourre-tout, et ne conserver que la liste blanche.

```ini
[RULES]
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p tcp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-gateway -p icmp -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vint-all -log nolog

# liste blanche vers la DMZ (AVANT le fourre-tout)
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p icmp -log nolog
# tout autre flux vers la DMZ est refusé et journalisé
FORWARD DROP   -source +sdn/vint-all -dest +sdn/vdmz-all -log info

# Internet
FORWARD ACCEPT -source +sdn/vint-all -log nolog
```

🧠 **Les règles sont évaluées dans l'ordre, première correspondance gagnante.**
C'est la base du filtrage, et la source d'erreur n°1. Relisez toujours vos règles
de haut en bas en vous demandant « à quelle ligne ce paquet s'arrête-t-il ? ».

### 🪤 La subtilité qui piège tout le monde : un paquet traverse DEUX VNets

Un flux `vint → vdmz` est évalué par `vint.fw` **et** par `vdmz.fw`. Il doit être
accepté **par les deux**. C'est pour ça que la liste blanche 22/80/443 apparaît
dans les deux fichiers, une fois en sortie et une fois en entrée.

La doc Proxmox est explicite :

> *« Since traffic passing the FORWARD chain is bi-directional, you need to create
> rules for both directions if you want traffic to pass both ways. »*

⚠️ Ne confondez pas avec le **conntrack**, qui gère le paquet **retour** d'une
connexion déjà acceptée. Ici on parle du **sens initial** : `A → B` et `B → A`
sont deux flux distincts, chacun a besoin de sa règle, dans les deux fichiers.

```
   vint.fw                          vdmz.fw
   ┌──────────────────┐             ┌──────────────────┐
   │ ACCEPT vint→vdmz │  ──── 22 ──►│ ACCEPT vint→vdmz │  ✅ passe
   │      :22         │             │      :22         │
   ├──────────────────┤             ├──────────────────┤
   │ (rien)           │  ◄─── 22 ───│ ACCEPT vint→vdmz │  ❌ jeté par vint.fw
   └──────────────────┘             └──────────────────┘
        ▲ le DROP est ici, pas là où on l'attend
```

C'est exactement le piège qui vous attend au **TP 12** avec la zone `services`.

### 5.3 Règles de `vdmz` (DMZ, régime strict)

`/etc/pve/sdn/firewall/vdmz.fw` :

```ini
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# --- Services d'infrastructure -----------------------------------------------
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p tcp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-gateway -p icmp -log nolog

# --- Entre machines de la DMZ : web uniquement -------------------------------
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog

# --- Flux entrant depuis l'interne (retour de connexion géré par conntrack) ---
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vint-all -dest +sdn/vdmz-all -p tcp -dport 443 -log nolog

# --- 🚨 DMZ vers INTERNE : INTERDIT, et on le journalise ----------------------
FORWARD DROP -source +sdn/vdmz-all -dest +sdn/vint-all -log warning

# --- DMZ vers Internet : mises à jour uniquement ------------------------------
FORWARD ACCEPT -source +sdn/vdmz-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vdmz-all -p udp -dport 123 -log nolog # NTP = UDP
```

🧠 **Pourquoi le DROP DMZ→INTERNE est-il placé avant les règles Internet ?**
Parce que les dernières règles n'ont pas de `-dest` et laisseraient passer un
`vdmz → vint:443`. Encore une fois : **l'ordre**.

### Appliquer

```bash
cp lab/firewall/vint.fw.example /etc/pve/sdn/firewall/vint.fw
cp lab/firewall/vdmz.fw.example /etc/pve/sdn/firewall/vdmz.fw
# adapter le numéro d'élève à l'intérieur
sed -i "s/10\.3\./10.$N./g" /etc/pve/sdn/firewall/*.fw

pvesh set /cluster/sdn
systemctl reload proxmox-firewall 2>/dev/null || systemctl restart proxmox-firewall
nft list ruleset | grep -c .
```

🪤 **Ces deux exemples contiennent déjà les règles `+sdn/vsrv-all` du TP 12.** Le VNet
`vsrv` n'existe pas encore : `proxmox-firewall` **ignore silencieusement** toute règle
qui référence un IPSet inconnu. Rien ne s'affiche à l'écran, il faut aller le lire :

```bash
journalctl -u proxmox-firewall -n 50 --no-pager | grep -i "could not find ipset"
```

Retirez ces lignes tant que vous n'avez pas fait le TP 12, ou assumez le bruit.

---

### 5.4 ⚠️ Ce que les règles VNet ne filtrent PAS — à lire deux fois

Le §5.2 laisse croire qu'un fichier `vint.fw` suffit à rouvrir ce que
`policy_forward: DROP` a fermé. **C'est faux**, et la documentation officielle est
formelle sur le périmètre de chaque zone :

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
   VM 10.N.10.50 ──► 1.1.1.1
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
nft add rule  inet dbg pre ip saddr 10.$N.20.101 tcp dport 443 meta nftrace set 1
nft monitor trace          # … puis lancez un curl depuis la VM, dans un autre terminal
nft delete table inet dbg  # ⚠ ne l'oubliez pas
```

Vous verrez le paquet passer de `forward` à `cluster-forward` puis `drop`, **sans
jamais visiter `bridge-vint`**. Voilà pourquoi vos règles VNet « ne servent à rien ».

#### Les règles `FORWARD` à ajouter dans `cluster.fw`

Elles reprennent la matrice du §1. Même logique d'ordre qu'au niveau VNet : les `DROP`
explicites **avant** les règles fourre-tout sans `-dest`.

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
dnsmasq-dhcp: DHCPOFFER(vdmz) 10.N.20.100 bc:24:11:...
dnsmasq-dhcp: Error sending DHCP packet to 10.N.20.100: Operation not permitted
```

Ajoutez donc **en tête** des `[RULES]` de chaque fichier VNet :

```ini
# DHCP : la requête vient de 0.0.0.0 (aucun IPSet ne matche) et l'OFFER repart
# de la gateway. Sans cette ligne, le drop final de la chaîne tue les deux.
FORWARD ACCEPT -p udp -dport 67:68 -log nolog
```

et, côté `cluster.fw`, laissez entrer la requête sur l'interface du VNet :

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

`ct-alpine-eN` → `Firewall → Options` : `Firewall: ✅`, `Input Policy: DROP`.
`ct-alpine-eN` → `Firewall → Add Security Group` : `srv-web`.

```bash
N=3     # ⚠ VOTRE numéro d'élève
cat > /etc/pve/firewall/${N}11.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
GROUP srv-web
IN ACCEPT -source +sdn/vint-all -p tcp -dport 22 -log nolog
IN ACCEPT -p icmp -log nolog
EOF
```

Sur `srv01-eN`, on n'ouvre PostgreSQL qu'à l'interne, et RDP de `win01` qu'à l'interne :

```bash
N=3     # ⚠ VOTRE numéro d'élève
cat > /etc/pve/firewall/${N}01.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source +sdn/vint-all -p tcp -dport 5432 -log nolog
IN ACCEPT -source +sdn/vint-all -p tcp -dport 22 -log nolog
IN ACCEPT -p icmp -log nolog
EOF
```

Et sur `win01-eN`, RDP réservé à la zone interne :

```bash
N=3     # ⚠ VOTRE numéro d'élève
cat > /etc/pve/firewall/${N}02.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source +sdn/vint-all -p tcp -dport 3389 -log info   # RDP
IN ACCEPT -source +sdn/vint-all -p tcp -dport 445 -log nolog   # SMB
IN ACCEPT -p icmp -log nolog
EOF
```

🧠 Notez le `-log info` sur RDP : **on journalise systématiquement les accès aux
services d'administration.** Un jour, quelqu'un vous demandera qui s'est connecté
et quand.

---

## 7. Tests de validation 🧪

Utilisez le script `lab/scripts/test-firewall.sh`, ou faites-le à la main.

### Depuis `srv01` (INTERNAL)

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm terminal ${N}01
```

| Test | Commande | Attendu |
|---|---|---|
| Gateway | `ping -c2 10.3.10.1` | ✅ |
| Interne → interne | `ping -c2 10.3.10.<win01>` | ✅ |
| Internet | `ping -c2 1.1.1.1` | ✅ |
| DNS | `getent hosts debian.org` | ✅ |
| Interne → DMZ HTTP | `curl -sI http://10.3.20.<alpine>` | ✅ 200 |
| Interne → DMZ SSH | `nc -zv 10.3.20.<alpine> 22` | ✅ |
| Interne → RDP Windows | `nc -zv 10.3.10.<win01> 3389` | ✅ |
| Interne → DMZ autre port | `nc -zvw2 10.3.20.<alpine> 3306` | ❌ timeout |

### Depuis `ct-alpine` (DMZ)

| Test | Commande | Attendu |
|---|---|---|
| Gateway | `ping -c2 10.3.20.1` | ✅ |
| Internet HTTPS | `curl -sI https://ubuntu.com` | ✅ |
| Mise à jour | `apk update` | ✅ |
| Internet ICMP | `ping -c2 1.1.1.1` | ❌ (non autorisé) |
| **DMZ → base** | `nc -zvw2 10.3.10.<srv01> 5432` | ❌ **timeout** 🎯 |
| **DMZ → SSH interne** | `nc -zvw2 10.3.10.<srv01> 22` | ❌ **timeout** 🎯 |
| **DMZ → RDP Windows** | `nc -zvw2 10.3.10.<win01> 3389` | ❌ **timeout** 🎯 |

🧠 Notez que **DMZ → INTERNAL:22 échoue** alors que `vdmz.fw` autorise bien `vint →
vdmz:22`. C'est la démonstration du paragraphe précédent : la règle est
**unidirectionnelle**. Le SSH part de l'interne, jamais l'inverse.

### Lire les journaux

```bash
# Les paquets refusés, en direct
tail -f /var/log/pve-firewall.log
journalctl -f -u proxmox-firewall

# Dans l'UI : Datacenter → Firewall → Log,  ou  VNet → Firewall → Log
```

Vous devez voir apparaître les tentatives DMZ → INTERNAL, taguées `warning`.
**C'est ça, un firewall qui travaille** : il ne bloque pas seulement, il raconte.

```bash
# Compteurs nftables : voir quelles règles matchent réellement
nft list ruleset | grep -B2 counter | head -40
```

---

## 8. Ouvrir un flux à la demande 🚪

Scénario : le développeur veut que `ct-alpine` (DMZ) interroge PostgreSQL sur `srv01`.

**La bonne réaction n'est pas d'ouvrir 5432 de la DMZ vers l'interne.** Options,
par ordre de préférence :

1. Déplacer la base derrière une **API** hébergée en interne, que la DMZ appelle en HTTPS.
2. Si c'est inévitable : ouvrir **une seule IP source vers une seule IP destination**,
   sur un seul port, et journaliser.

```ini
# Dans vdmz.fw — AVANT la règle DROP globale DMZ→INTERNE
FORWARD ACCEPT -source 10.3.20.101 -dest 10.3.10.100 -p tcp -dport 5432 -log info \
    # ticket INFRA-421, ct-alpine -> srv01, revoir le 2026-12-31
```

🧠 **Documentez chaque exception** dans le commentaire : qui, pourquoi, jusqu'à quand.
Un firewall sans commentaires devient, en deux ans, un tas de règles que personne
n'ose supprimer.

---

## 9. Pièges et dépannage 🔧

| Symptôme | Cause | Solution |
|---|---|---|
| Les règles VNet n'ont aucun effet | `pve-firewall` iptables actif | `nftables: 1` dans `host.fw` + `apt install proxmox-firewall` |
| Plus d'accès à `:8006` | `policy_in: DROP` sans règle d'autorisation | Console physique → `pve-firewall stop`, corriger `cluster.fw` |
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
- [ ] INTERNAL → DMZ sur 3306 : ❌
- [ ] DMZ → Internet sur 443 : ✅
- [ ] **DMZ → INTERNAL : ❌ sur tous les ports**
- [ ] Les refus DMZ → INTERNAL apparaissent dans les journaux
- [ ] J'ai toujours accès à l'interface web et au SSH du nœud
- [ ] Je sais expliquer pourquoi l'ordre des règles est critique

---

## 🎁 Bonus

1. **Publier `ct-alpine` sur Internet** : ajoutez un DNAT sur l'hôte pour exposer le
   port 80 du conteneur sur `172.30.30.15N:8080`, et la règle FORWARD correspondante. Puis
   demandez-vous pourquoi Proxmox ne propose pas ça nativement (indice : où placer la
   règle dans un cluster où la VM peut migrer ?).
2. **Isolation totale** : activez `isolate-ports` sur `vdmz` **en plus** des règles.
   Vérifiez que `ct-alpine` ne voit plus `ct-rocky`, même en ARP.
3. **Générez la matrice de flux depuis les fichiers** : un script qui lit les `.fw` et
   produit un tableau markdown. Excellent pour les audits.
4. Comparez `nft list ruleset` avant/après l'activation d'un VNet firewall. Repérez
   les chaînes `proxmox-firewall-forward` et les IPSets `sdn/*`.

➡️ Fin du jour 2 🎉 · Suite : [TP 10 — Cloud-image en CLI, cloud-init et clonage](10-cloudinit-cli-clonage.md)
