# TP 19 — Migration à chaud et Haute Disponibilité ⚡

⏱️ **1 h** · Jour 4

Objectif : exploiter le cluster maintenant que Ceph est en place. Migrer des machines
sans interruption, mettre en place la HA, et provoquer une panne pour voir le système
réagir tout seul.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-ha-manager.html>

---

## 1. Les trois niveaux de résilience 🧠

```
   ① MIGRATION            ② STOCKAGE PARTAGÉ      ③ HAUTE DISPONIBILITÉ
   ─────────────          ─────────────────       ──────────────────────
   Je décide de           Le disque n'appartient  Le cluster décide seul
   déplacer une VM        plus à un seul nœud     de redémarrer une VM
                          (Ceph, TP 18)            ailleurs après une panne

   Panne planifiée        Rend ② et ③ possibles   Panne non planifiée
   (maintenance)          et rapides               (nœud mort)

   Interruption : 0       —                        Interruption : le temps
                                                   du fencing + du boot
                                                   (~2-3 min)
```

🧠 **La HA n'est pas de la magie.** Elle *redémarre* une VM ailleurs — la VM subit
l'équivalent d'une coupure de courant. Ce qui doit être sans coupure (une base de
données critique), c'est à l'application de le gérer, en cluster applicatif.

---

## 2. Migration hors ligne vs à chaud 🚚

```
   HORS LIGNE (offline)              À CHAUD (online / live)
   ────────────────────              ───────────────────────
   1. arrêt de la VM                 1. copie de la RAM (pré-copie itérative)
   2. copie du disque si local       2. dernière passe, VM figée ~50 ms
   3. démarrage sur l'autre nœud     3. reprise sur l'autre nœud
                                     4. bascule du réseau

   Interruption = durée totale       Interruption ≈ 50 ms (imperceptible)
   Aucun prérequis                   Exige : CPU compatible + même stockage
                                     ou --with-local-disks
```

### Prérequis de la migration à chaud

| Prérequis | Vérification |
|---|---|
| Même type de CPU exposé | `qm config <id> \| grep cpu` → `x86-64-v2-AES`, pas `host` |
| Stockage partagé (`vm-store`/Ceph), **ou** `--with-local-disks` | `pvesm status` |
| Le bridge/VNet existe sur la cible | EVPN : ✅ partout (TP 17) |
| Pas de matériel passthrough | pas de PCI, pas d'USB attaché |
| Le cluster est *quorate* | `pvecm status` |

🪤 **`cpu: host` interdit la migration** entre nœuds au CPU différent. Si vous avez
gardé `host` sur une VM du jour 1, corrigez :

```bash
qm set <vmid> --cpu x86-64-v2-AES    # nécessite un arrêt/démarrage
```

---

## 3. Migrer 🚀

### Sans stockage partagé (disque local)

```bash
VMID=$(qm list | awk '/evpn-prod/{print $1}')     # votre VM du TP 17 — depuis le nœud où elle tourne
time qm migrate $VMID pve5 --online --with-local-disks    # vers un nœud autre que le vôtre
```

Observez la tâche : Proxmox copie le disque **puis** la RAM. Sur 20 Go, comptez
plusieurs minutes.

🪤 **Si la commande refuse** avec `can't migrate ... as it's a clone of ...`, votre VM
est un **clone lié** : son disque n'est qu'une couche copy-on-write au-dessus de
l'image du template, laquelle n'existe pas sur le nœud cible. Deux sorties :

```bash
# A. la convertir en clone complet, sur place
qm move-disk $VMID scsi0 local-lvm --delete 1

# B. mieux : l'envoyer directement sur Ceph — c'est l'objet du paragraphe suivant
qm move-disk $VMID scsi0 vm-store --delete 1
```

🧠 **`qm move-disk` casse le lien vers l'image de base** : il écrit un disque complet
et indépendant. C'est la manœuvre à connaître pour « détacher » un clone lié — et
c'est aussi ce qui explique pourquoi le TP 17 clone en `--full 1`.

### Avec Ceph

```bash
VMID=$(qm list | awk '/evpn-prod/{print $1}')     # votre VM du TP 17 — depuis le nœud où elle tourne
# Déplacer d'abord le disque sur le pool Ceph
qm move-disk $VMID scsi0 vm-store --delete 1
qm config $VMID | grep scsi0

time qm migrate $VMID pve2 --online                 # un autre nœud que le vôtre
```

🎯 **Comparez les deux chronos.** Avec un stockage partagé, seule la RAM transite :
quelques secondes au lieu de plusieurs minutes. Le disque, lui, ne bouge pas d'un
octet — il n'a jamais appartenu à un nœud en particulier.

```bash
# La preuve : l'image RBD est inchangée, seule la VM a changé de nœud
rbd -p vm-store info vm-$VMID-disk-0
ceph osd map vm-store vm-$VMID-disk-0
```

### Le test qui prouve

```bash
# Depuis votre PC, un ping continu
ping 10.60.10.<ip-de-la-vm>
```

```bash
# ⚠ la VM a changé de nœud : lancez ceci depuis le nœud où elle tourne (qm list)
qm migrate $VMID pve4 --online
```

✅ Zéro ou un paquet perdu, grâce à la gateway anycast EVPN.

### Migration en masse

```bash
# Vider un nœud avant maintenance
ha-manager crm-command node-maintenance enable pve5

# ou, sans HA :
for id in $(qm list | awk 'NR>1 && $3=="running" {print $1}'); do
  qm migrate $id pve2 --online
done
```

🌐 Équivalent graphique : `votre nœud → clic droit → Bulk Migrate`.

---

## 4. Régler le réseau de migration 🔧

Par défaut la migration passe par le réseau de management — donc en concurrence avec
Corosync. En production, on lui dédie un lien.

🌐 `Datacenter → Options → Migration Settings`

| Champ | Valeur (lab) | Production |
|---|---|---|
| Network | `172.30.30.0/24` | un VLAN dédié 10 Gb/s |
| Type | `secure` (chiffré SSH) | `insecure` si le réseau est de confiance |

```bash
cat /etc/pve/datacenter.cfg
# migration: network=172.30.30.0/24,type=secure
```

🧠 `insecure` n'est pas « non sécurisé au hasard » : cela veut dire « transfert en clair,
parce que le réseau est physiquement isolé ». Sur un lien dédié, cela double
facilement le débit. Sur un réseau partagé, gardez `secure`.

---

## 5. Et si on n'avait pas Ceph ? 🔁

Question légitime : que fait-on sur un cluster **sans** stockage partagé ?

| Approche | Ce que ça donne | Limite |
|---|---|---|
| `--with-local-disks` à chaque migration | ça marche, mais on copie tout le disque | plusieurs minutes, et pas de HA |
| **Réplication de stockage** | copie périodique du disque sur un autre nœud | ⚠️ exige **ZFS** — hors périmètre de cette formation |
| Stockage partagé (NFS, iSCSI) | rapide, HA possible | un point de défaillance unique |
| **Ceph** | rapide, HA, sans SPOF | 3 nœuds minimum, réseau exigeant |

🧠 **La réplication de stockage de Proxmox (`pvesr`) ne fonctionne qu'avec ZFS**, car
elle repose sur `zfs send/receive` — l'envoi des seuls blocs modifiés depuis le dernier
snapshot. Nous avons délibérément installé nos nœuds en **ext4 + LVM-thin** : plus
simple, moins gourmand en RAM, et suffisant puisque Ceph nous donne du vrai stockage
partagé. Sachez que `pvesr` existe, et pourquoi vous ne pouvez pas l'utiliser ici.

```bash
pvesr status          # vide : aucun job possible sans ZFS
```

🧠 **RPO (Recovery Point Objective)** : avec de la réplication toutes les 15 minutes, on
perd au maximum 15 minutes de données à la panne. Avec Ceph, le RPO est **nul** : les
trois copies sont synchrones. C'est la différence entre « je perds un quart d'heure »
et « je ne perds rien ».

⚠️ **Ni la réplication ni Ceph ne sont des sauvegardes.** Une donnée supprimée est
répliquée… supprimée. La sauvegarde, c'était le TP 15.

---

## 6. La Haute Disponibilité 🏥

### Le principe

```
      pve3 tombe (courant, noyau, matériel)
              │
              ▼
   ┌──────────────────────────────────────┐
   │ Les 5 autres nœuds ont le quorum (5≥4)│
   │ Corosync constate la disparition      │
   └───────────────┬──────────────────────┘
                   ▼
   ┌──────────────────────────────────────┐
   │ FENCING : pve3 est présumé mort.      │
   │ Son watchdog matériel l'a rebooté     │
   │ (il ne peut plus écrire nulle part).  │
   │ ⏱ ~60 secondes                        │
   └───────────────┬──────────────────────┘
                   ▼
   ┌──────────────────────────────────────┐
   │ Le CRM choisit un nœud cible et       │
   │ DÉMARRE la VM dessus.                 │
   └──────────────────────────────────────┘
```

🧠 **Le fencing est le cœur du système.** Avant de démarrer une VM ailleurs, le cluster
doit être *certain* qu'elle ne tourne plus sur le nœud disparu — sinon deux instances
écrivent sur le même disque partagé et le corrompent en quelques secondes. Proxmox
utilise un **watchdog** (matériel ou `softdog`) : un nœud qui perd le quorum ne peut
plus caresser son watchdog, qui le redémarre de force.

### Prérequis

| Prérequis | Pourquoi | État dans notre lab |
|---|---|---|
| Cluster *quorate* | sinon aucune décision n'est prise | ✅ TP 16 |
| **Stockage partagé** | la VM doit trouver son disque ailleurs | ✅ Ceph, TP 18 |
| Watchdog actif | `cat /proc/devices \| grep watchdog` | ✅ `softdog` par défaut |
| VNet disponible partout | sinon la VM redémarre sans réseau | ✅ EVPN, TP 17 |

🚨 **Le disque de la VM déclarée en HA doit être sur `vm-store` (Ceph)**, pas sur
`local-lvm`. Sinon la HA échouera à la première panne : le disque n'existe nulle part
ailleurs.

```bash
VMID=$(qm list | awk '/evpn-prod/{print $1}')   # votre VM du TP 17 (sur son nœud actuel)
qm config $VMID | grep -E 'scsi0|virtio0'       # doit pointer sur vm-store
qm move-disk $VMID scsi0 vm-store --delete 1    # si ce n'est pas le cas
```

### Configurer

**① Un groupe HA** (où la VM a le droit de tourner, et avec quelle préférence)

🌐 `Datacenter → HA → Groups → Create`

| Champ | Valeur |
|---|---|
| ID | `grp-prod` |
| Nodes | `pve2:100,pve3:50,pve4:50` |
| restricted | ✅ (uniquement ces nœuds) |
| nofailback | ❌ (revenir sur pve2 dès qu'il est de retour) |

```bash
pvesh create /cluster/ha/groups --group grp-prod \
  --nodes "pve2:100,pve3:50,pve4:50" --restricted 1 --nofailback 0
```

Les chiffres sont des **priorités** : la valeur la plus élevée gagne.

⚠️ Le groupe est `restricted` : si votre VM tourne ailleurs que sur `pve2`, `pve3` ou
`pve4` (vous êtes sur `pve5`/`pve6`, ou elle n'est pas rentrée du TP 17 §9), le CRM la
**migre** dès la déclaration de la ressource. C'est attendu — regardez-le faire.

**② Déclarer la ressource**

```bash
pvesh create /cluster/ha/resources --sid vm:$VMID --group grp-prod \
  --state started --max_restart 2 --max_relocate 2
pvesh get /cluster/ha/resources
ha-manager status
```

🌐 `Datacenter → HA → Resources → Add`

```bash
ha-manager status --verbose
systemctl status pve-ha-crm pve-ha-lrm --no-pager | head -12
```

| Composant | Rôle |
|---|---|
| **CRM** (Cluster Resource Manager) | Un seul actif dans le cluster (le *master*). Décide. |
| **LRM** (Local Resource Manager) | Un par nœud. Exécute les décisions du CRM. |

---

## 7. Provoquer la panne 🔥

**Expérience collective, avec l'accord du formateur.** Choisissez un nœud qui n'est ni
`pve1` (exit node EVPN primaire et hôte de PBS) ni un monitor Ceph, pour rester simple.

```bash
# Terminal 1 — sur un nœud survivant
watch -n1 'ha-manager status; echo; pvecm status | grep -E "Quorate|Total"'

# Terminal 2 — un ping continu vers la VM en HA
ping 10.60.10.<ip>
```

Puis, **débranchez physiquement l'alimentation** du nœud cible.
(Ou, plus doux : `echo c > /proc/sysrq-trigger` — panique noyau immédiate.)

### Chronologie attendue

```
   T+0 s     le nœud disparaît, le ping vers la VM s'arrête
   T+5 s     Corosync signale la perte du membre
   T+~60 s   fencing : le watchdog a rebooté le nœud disparu
   T+~70 s   le CRM place la ressource sur un autre nœud
   T+~90 s   la VM démarre
   T+~120 s  le ping reprend ✅
```

```bash
ha-manager status
journalctl -u pve-ha-crm -n 40 --no-pager
journalctl -u pve-ha-lrm -n 40 --no-pager
qm list        # la VM tourne maintenant ailleurs
```

Rebranchez le nœud. Avec `nofailback: 0`, la VM revient d'elle-même sur `pve2`.

🧠 **Deux minutes d'interruption.** C'est le vrai chiffre à annoncer à un client, pas
« la HA, c'est du zéro downtime ». Si le zéro downtime est exigé, il faut du clustering
applicatif (PostgreSQL en streaming replication + Patroni, un load-balancer devant
plusieurs frontaux, etc.) — l'infrastructure seule ne peut pas y arriver.

---

## 8. Règles d'affinité (PVE 9) 🧲

PVE 9 a introduit des règles pour contraindre le placement des ressources HA.

| Type de règle | Effet |
|---|---|
| **Affinité positive** | Ces VM doivent rester **ensemble** (appli + son cache) |
| **Affinité négative** | Ces VM doivent rester **séparées** (deux nœuds d'un cluster applicatif) |
| **Contrainte de nœud** | Cette VM ne tourne que sur certains nœuds (licence, matériel) |

🌐 `Datacenter → HA → Rules`

🧠 **Cas d'école** : deux frontaux web derrière un load-balancer. S'ils atterrissent sur
le même nœud et que ce nœud tombe, la redondance n'a servi à rien. Une règle
d'anti-affinité l'empêche.

---

## 9. Ce qu'il faut retenir 🎓

| Besoin | Réponse |
|---|---|
| Maintenance planifiée | Migration à chaud, 0 interruption |
| Nœud qui meurt, VM peu critique | HA sur Ceph, ~2 min d'interruption |
| Nœud qui meurt, VM critique | HA **+** clustering applicatif |
| Protection contre l'erreur humaine | Snapshots + **sauvegardes** (TP 15) |
| Protection contre le sinistre | Sauvegardes **hors site** (TP 15) |
| Zéro perte de données | Stockage synchrone : **Ceph** (TP 18) |
| Perte de données limitée, sans Ceph | Réplication ZFS — nécessite du ZFS |

🪤 **La HA ne protège de rien d'autre qu'une panne de nœud.** Elle ne vous sauve ni d'un
`rm -rf`, ni d'un ransomware, ni d'une mise à jour ratée, ni d'un incendie. Ces
scénarios-là relèvent de la sauvegarde — le TP 15, et c'est le plus important des deux.

Ceph non plus, d'ailleurs : il réplique fidèlement vos suppressions, en trois
exemplaires et à la vitesse du réseau.

---

## ✅ Checklist de validation

- [ ] Une migration à chaud avec disque local fonctionne (et je connais sa durée)
- [ ] Une migration à chaud sur Ceph fonctionne (et c'est bien plus rapide)
- [ ] Je sais expliquer pourquoi `pvesr` (réplication) est inutilisable sans ZFS
- [ ] Le ping ne perd aucun paquet pendant la migration
- [ ] Le réseau de migration est configuré dans `datacenter.cfg`
- [ ] Un groupe HA existe avec des priorités
- [ ] Une VM est déclarée en ressource HA et `ha-manager status` est vert
- [ ] La panne d'un nœud a bien redémarré la VM ailleurs, en ~2 min
- [ ] Je sais expliquer ce qu'est le **fencing** et pourquoi il est indispensable
- [ ] Je sais dire ce que la HA **ne** protège **pas**

---

## 🎁 Bonus

1. **Chronométrez précisément** la bascule HA (`journalctl -u pve-ha-crm` avec
   horodatage). Comparez avec le SLA d'un hébergeur.
2. **Anti-affinité** : déclarez deux frontaux web en HA avec une règle de séparation,
   puis provoquez une panne et vérifiez qu'ils ne se retrouvent jamais ensemble.
3. **`softdog` vs watchdog matériel** : `lsmod | grep -i dog`. Si votre serveur a un
   watchdog IPMI, activez-le dans `/etc/default/pve-ha-manager`. Pourquoi est-ce plus
   fiable qu'un watchdog logiciel ?
4. **Le scénario catastrophe** : coupez le réseau de 3 nœuds sur 6. Aucune moitié n'a le
   quorum. Que se passe-t-il ? Est-ce le bon comportement ? (Réponse : oui — mieux vaut
   tout figer que corrompre.)

➡️ Suite : [TP 20 — Pulse, une autre UI de supervision](20-pulse-monitoring.md)
