# TP 17 — Stockage partagé, migration à chaud et Haute Disponibilité ⚡

⏱️ **1 h** · Jour 4

Objectif : exploiter le cluster. Migrer des machines sans interruption, mettre en place
la réplication et la HA, et provoquer une panne pour voir le système réagir tout seul.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-ha-manager.html>

---

## 1. Les trois niveaux de résilience 🧠

```
   ① MIGRATION            ② RÉPLICATION           ③ HAUTE DISPONIBILITÉ
   ─────────────          ──────────────          ──────────────────────
   Je décide de           Le disque est copié     Le cluster décide seul
   déplacer une VM        régulièrement sur       de redémarrer une VM
                          un autre nœud            ailleurs après une panne

   Panne planifiée        Perte de données        Panne non planifiée
   (maintenance)          limitée au RPO          (nœud mort)

   Interruption : 0       Interruption : le       Interruption : le temps
                          temps de démarrer        du fencing + du boot
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
| Stockage partagé, **ou** `--with-local-disks` | `pvesm status` |
| Le bridge/VNet existe sur la cible | EVPN : ✅ partout (TP 16) |
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
N=3
time qm migrate N60 pve5 --online --with-local-disks
```

Observez la tâche : Proxmox copie le disque **puis** la RAM. Sur 20 Go, comptez
plusieurs minutes.

### Avec stockage partagé

```bash
# Déplacer d'abord le disque sur le NFS
qm move-disk N60 scsi0 nfs-lab --delete 1

time qm migrate N60 pve2 --online
```

🎯 **Comparez les deux chronos.** Avec le stockage partagé, seule la RAM transite :
quelques secondes au lieu de plusieurs minutes. C'est exactement pour ça qu'on a monté
le NFS au TP 14.

### Le test qui prouve

```bash
# Depuis votre PC, un ping continu
ping 10.60.10.<ip-de-la-vm>
```

```bash
qm migrate N60 pve4 --online
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

🌐 Équivalent graphique : `pveN → clic droit → Bulk Migrate`.

---

## 4. Régler le réseau de migration 🔧

Par défaut la migration passe par le réseau de management — donc en concurrence avec
Corosync. En production, on lui dédie un lien.

🌐 `Datacenter → Options → Migration Settings`

| Champ | Valeur (lab) | Production |
|---|---|---|
| Network | `192.168.50.0/24` | un VLAN dédié 10 Gb/s |
| Type | `secure` (chiffré SSH) | `insecure` si le réseau est de confiance |

```bash
cat /etc/pve/datacenter.cfg
# migration: network=192.168.50.0/24,type=secure
```

🧠 `insecure` n'est pas « non sécurisé au hasard » : cela veut dire « transfert en clair,
parce que le réseau est physiquement isolé ». Sur un lien dédié, cela double
facilement le débit. Sur un réseau partagé, gardez `secure`.

---

## 5. Réplication ZFS (si vous êtes en ZFS) 🔁

Sans stockage partagé, la réplication est la meilleure approximation : le disque est
copié périodiquement sur un autre nœud, en envoyant seulement les blocs modifiés.

```bash
pvesh create /nodes/pve3/replication --id N60-0 --target pve5 --schedule '*/15' --rate 50
pvesh get /nodes/pve3/replication
pvesr status
pvesr run --id N60-0 --verbose
```

🌐 `VM → Replication → Add`

```
   pve3                          pve5
   [VM 360] ──── zfs send ───► [copie]
     disque       toutes           RPO = 15 min
                  les 15 min
```

🧠 **RPO (Recovery Point Objective)** : en cas de perte de `pve3`, vous perdez au
maximum 15 minutes de données. La migration devient aussi quasi instantanée, puisque
l'essentiel du disque est déjà de l'autre côté.

⚠️ Réplication ≠ sauvegarde. Une donnée supprimée est répliquée… supprimée. La
sauvegarde, c'est le TP 18.

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

| Prérequis | Pourquoi |
|---|---|
| Cluster *quorate* | sinon aucune décision n'est prise |
| **Stockage partagé** (ou réplication) | la VM doit trouver son disque ailleurs |
| Watchdog actif | `cat /proc/devices \| grep watchdog` |
| VNet disponible partout | EVPN : ✅ |

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

**② Déclarer la ressource**

```bash
pvesh create /cluster/ha/resources --sid vm:N60 --group grp-prod \
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
`pve1` (exit node primaire) ni celui qui héberge le NFS.

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
| Nœud qui meurt, VM peu critique | HA, ~2 min d'interruption |
| Nœud qui meurt, VM critique | HA **+** clustering applicatif |
| Protection contre l'erreur humaine | Snapshots + **sauvegardes** (TP 18) |
| Protection contre le sinistre | Sauvegardes **hors site** (TP 18) |
| Zéro perte de données | Stockage synchrone (Ceph) ou réplication applicative |

🪤 **La HA ne protège de rien d'autre qu'une panne de nœud.** Elle ne vous sauve ni d'un
`rm -rf`, ni d'un ransomware, ni d'une mise à jour ratée, ni d'un incendie. Ces
scénarios-là relèvent de la sauvegarde. C'est le TP suivant, et c'est le plus important
des deux.

---

## ✅ Checklist de validation

- [ ] Une migration à chaud avec disque local fonctionne (et je connais sa durée)
- [ ] Une migration à chaud sur stockage partagé fonctionne (et c'est bien plus rapide)
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

➡️ Suite : [TP 18 — Proxmox Backup Server](18-proxmox-backup-server.md)
