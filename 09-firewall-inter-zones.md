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

⚠️ **Redémarrez vos VM et CT** après le passage à nftables : leurs chaînes de filtrage
sont recréées au démarrage du guest.

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
   │     FORWARD uniquement  ·   la segmentation inter-réseaux ★
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
| `pc_eleve` | `172.30.30.10N` | mon poste |

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
```

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

C'est le cœur du TP.

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
| Les VM n'ont plus Internet | `policy_forward: DROP` sans règles VNet | Écrire les règles VNet, ou repasser `policy_forward: ACCEPT` le temps de déboguer |
| Une règle « ne marche pas » | Une règle précédente a déjà matché | Relire de haut en bas ; ajouter `-log info` pour tracer |
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

- [ ] `nftables: 1` est actif et `proxmox-firewall` tourne
- [ ] `policy_forward: DROP` au niveau Datacenter
- [ ] `vint.fw` et `vdmz.fw` existent et sont appliqués
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
