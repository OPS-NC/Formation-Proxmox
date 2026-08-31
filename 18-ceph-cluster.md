# TP 18 — Cluster Ceph intégré à Proxmox 🐙

⏱️ **1 h 45** · Jour 4

Objectif : monter un stockage distribué à trois copies, sans point de défaillance
unique, sur les six nœuds du cluster. Et pour cela : faire de la place sur le disque
système en manipulant LVM à la main — parce que l'interface web ne sait pas le faire.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pveceph.html>
📖 Wiki : <https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster>

---

## 1. Ce que Ceph résout 🧠

Au TP 14, votre NFS marchait très bien… jusqu'à ce que vous coupiez le serveur.
C'est un **point de défaillance unique**.

```
   NFS (TP 14)                          CEPH (TP 18)
   ───────────                          ────────────
        ┌──────┐                     ┌────┬────┬────┬────┬────┬────┐
        │ 1 PC │                     │pve1│pve2│pve3│pve4│pve5│pve6│
        └───┬──┘                     └──┬─┴──┬─┴──┬─┴──┬─┴──┬─┴──┬─┘
            │                           └────┴────┴────┴────┴────┘
   ┌────┬───┴┬────┐                         chaque bloc écrit
   │pve1│pve2│pve3│                         en 3 copies, sur
   └────┴────┴────┘                         3 nœuds différents

   Le PC tombe → TOUT gèle              2 nœuds tombent → ça continue
```

### Le vocabulaire, en une image

```
   ┌──────────────────────────────────────────────────────────────┐
   │  MON  (monitor)     La carte du cluster. Qui existe, où,      │
   │                     dans quel état. Il en faut ≥ 3, impairs.  │
   │                     C'est le « corosync » de Ceph.            │
   ├──────────────────────────────────────────────────────────────┤
   │  MGR  (manager)     Les métriques, le tableau de bord,        │
   │                     l'autoscaler de PG. 1 actif + 1 veille.   │
   ├──────────────────────────────────────────────────────────────┤
   │  OSD  (object       UN par disque (ou par volume). C'est lui   │
   │        storage      qui stocke réellement les octets et qui    │
   │        daemon)      réplique vers ses pairs.                   │
   ├──────────────────────────────────────────────────────────────┤
   │  POOL               Un espace logique, avec sa règle de        │
   │                     réplication (size 3 / min_size 2).        │
   ├──────────────────────────────────────────────────────────────┤
   │  PG   (placement    Les « tiroirs » qui répartissent les       │
   │        group)       objets sur les OSD. Gérés automatiquement. │
   ├──────────────────────────────────────────────────────────────┤
   │  CRUSH              L'algorithme qui décide « cet objet va sur │
   │                     ces 3 OSD » — sans annuaire central.      │
   └──────────────────────────────────────────────────────────────┘
```

🧠 **`size 3, min_size 2`**, la règle d'or : trois copies de chaque bloc, et l'écriture
n'est acceptée que si au moins deux sont confirmées. Traduction opérationnelle : vous
survivez à la perte d'**un** nœud sans perdre le service, et à la perte de **deux** sans
perdre de données (mais le pool passe en lecture seule).

---

## 2. ⚠️ Ce lab n'est pas une architecture Ceph recommandable

Soyons honnêtes tout de suite — vous devrez le dire à un client.

| Recommandation officielle | Notre lab | Conséquence |
|---|---|---|
| **≥ 10 Gb/s dédiés** à Ceph | 1 Gb/s, partagé avec tout | Performances faibles ; risque pour Corosync |
| Réseau **public** et **cluster** séparés | un seul LAN plat | Le trafic de réplication écrase le reste |
| Corosync sur un lien **dédié** | le même LAN | Un *backfill* Ceph peut déstabiliser le quorum |
| **Un disque entier** par OSD, en SSD | un volume LVM sur le disque système | I/O système et Ceph en concurrence |
| ≥ 8 Gio de RAM **par OSD** | ce qu'il reste | Ceph consommera beaucoup |
| Pas de RAID matériel, HBA direct | selon le matériel | — |

🎯 **Ce qu'on apprend quand même, et qui est parfaitement transposable** : le
déploiement, la manipulation LVM, le comportement de CRUSH, la reconstruction après
panne, le monitoring, et surtout **le raisonnement**.

⚠️ **Précaution obligatoire** : limitez le débit de reconstruction, sinon un
rééquilibrage saturera le lien et fera perdre le quorum Corosync. On le fait au §7.

---

## 3. Le problème du disque : où mettre l'OSD ? 🧩

Un OSD a besoin d'un **périphérique bloc dédié**. Ceph accepte trois formes :
un disque entier, une partition, ou un **volume logique LVM**.

Mais l'interface web de Proxmox ne propose que les **disques entiers non utilisés**.
Or votre disque unique est intégralement occupé :

```bash
lsblk
vgs
lvs -a -o +devices
```

Sortie typique d'une installation Proxmox sur un seul disque :

```
  LV            VG   Attr       LSize    Data%
  data          pve  twi-aotz-- 340.00g  12.5      ← le pool LVM-thin (local-lvm)
  root          pve  -wi-ao----  58.00g
  swap          pve  -wi-ao----   8.00g
  [data_tdata]  pve  Twi-ao---- 340.00g
  [data_tmeta]  pve  ewi-ao----   3.48g
```

```bash
vgs -o vg_name,vg_size,vg_free
```

👉 **Tout dépend de cette dernière commande.** Trois scénarios :

```
   ┌─────────────────────────────────────────────────────────────┐
   │ ① VG_FREE ≥ 60 Go          → chemin A : lvcreate direct 🎉  │
   │    (vous avez réduit maxvz à l'installation, TP 01 §3.1)     │
   ├─────────────────────────────────────────────────────────────┤
   │ ② VG_FREE ≈ 0              → chemin B : recréer le thin pool │
   │    (le cas par défaut)        ⚠ destructif, sauvegarde requise│
   ├─────────────────────────────────────────────────────────────┤
   │ ③ Un second disque libre   → chemin C : pveceph osd create   │
   │                               /dev/sdb 🎉                    │
   └─────────────────────────────────────────────────────────────┘
```

### 🪤 Pourquoi ne pas simplement réduire le thin pool ?

C'est la question que tout le monde pose. Essayez :

```bash
lvreduce -L -60G pve/data
```

```
  Thin pool volumes pve/data_tdata cannot be reduced in size yet.
```

**LVM ne sait pas réduire un thin pool.** Ce n'est pas un bug, c'est une limite de
conception : les blocs d'un pool thin ne sont pas alloués linéairement. Il peut y avoir
des données allouées tout à la fin du pool, et dm-thin ne fournit aucun mécanisme pour
les défragmenter vers le début. Il existe des outils tiers (`thin_shrink`) qui réécrivent
les métadonnées, mais on ne joue pas à ça sur des données réelles.

**La seule voie propre : sauvegarder, détruire, recréer plus petit, restaurer.**
C'est exactement pour cette raison que le TP 15 (PBS) vient **avant** celui-ci.

---

## 4. Chemin A — il reste de la place dans le VG 🎉

> 💡 Le script `lab/scripts/ceph-prep-lvm.sh --check` fait tout le diagnostic du §3
> pour vous et vous indique quel chemin suivre. Lancez-le d'abord.

```bash
bash /root/formation/lab/scripts/ceph-prep-lvm.sh --check
```

```bash
vgs -o vg_name,vg_free
# pve   80.00g   → parfait
```

```bash
lvcreate -n ceph-osd -L 60G pve
lvs pve
ls -l /dev/pve/ceph-osd
```

Ou, avec le script :

```bash
bash /root/formation/lab/scripts/ceph-prep-lvm.sh --size 60G
```

Passez directement au §6.

---

## 5. Chemin B — recréer le thin pool plus petit ⚠️

**C'est le chemin par défaut, et il est destructif.** Lisez tout avant de taper.

```
   ① Sauvegarder tous les guests vers PBS
   ② Vérifier que les sauvegardes sont là et vérifiées
   ③ Détruire les guests
   ④ lvremove pve/data       ← le thin pool disparaît
   ⑤ lvcreate --thinpool data -L <plus petit>
   ⑥ lvcreate -n ceph-osd -L <le reste>
   ⑦ Restaurer les guests depuis PBS
```

### 5.1 Sauvegarder — et vérifier

```bash
N=3
# Tout le pool de l'élève, vers PBS
vzdump --pool eleve$N --storage pbs-lab --mode snapshot --compress zstd

pvesm list pbs-lab
```

🌐 Sur PBS : `Datastore → lab-store → <votre namespace> → Verify`.

🚨 **Ne passez à l'étape suivante que si la vérification est verte.** Vous êtes sur le
point d'effacer les originaux.

```bash
# Notez la configuration de chaque guest — utile en cas de restauration partielle
mkdir -p /root/pre-ceph
cp /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf /root/pre-ceph/ 2>/dev/null
lvs > /root/pre-ceph/lvs-avant.txt
vgs > /root/pre-ceph/vgs-avant.txt
ls -l /root/pre-ceph/
```

### 5.2 Libérer `local-lvm`

```bash
# Arrêter et détruire les guests dont les disques sont sur local-lvm
for id in $(qm list | awk 'NR>1{print $1}'); do
  qm stop $id 2>/dev/null; sleep 2; qm destroy $id --purge
done
for id in $(pct list | awk 'NR>1{print $1}'); do
  pct stop $id 2>/dev/null; sleep 1; pct destroy $id --purge
done

# Vérifier qu'il ne reste AUCUN volume dans le pool
lvs pve
```

Si des volumes `vm-*-disk-*` subsistent (templates, disques orphelins) :

```bash
lvs -o lv_name,pool_lv | grep data
lvremove pve/vm-390-disk-0        # un par un, en connaissance de cause
```

### 5.3 La chirurgie

```bash
# 1. Retirer le stockage de Proxmox pour qu'il n'écrive plus dedans
pvesm set local-lvm --disable 1

# 2. Supprimer le thin pool
lvremove -y pve/data
vgs -o vg_name,vg_size,vg_free        # tout l'espace est libre

# 3. Adapter les tailles à VOTRE disque.
#    Exemple pour un VG de ~400 Go, root et swap déjà pris :
#      thin pool 200 Go   +   OSD Ceph 120 Go   +   marge
lvcreate --type thin-pool -n data -L 200G pve
lvcreate -n ceph-osd -L 120G pve

lvs pve
vgs -o vg_name,vg_free
```

🪤 **Laissez toujours 5 à 10 % du VG libres.** LVM en a besoin pour les snapshots et
les métadonnées, et un VG à 100 % vous interdit toute manœuvre future. Ne remplissez
jamais avec `-l 100%FREE`.

```bash
# 4. Réactiver le stockage
pvesm set local-lvm --disable 0
pvesm status
```

> 💡 Les étapes 5.3 sont scriptées, avec tous les garde-fous :
> ```bash
> bash /root/formation/lab/scripts/ceph-prep-lvm.sh \
>      --size 120G --recreate-thinpool 200G --i-know
> ```
> Le script refuse de continuer s'il reste une VM, un conteneur ou un volume dans le
> pool. Lisez-le avant de l'exécuter.

### 5.4 Restaurer les guests

```bash
N=3
pvesm list pbs-lab
qm restore ${N}01 pbs-lab:backup/vm/${N}01/<timestamp> --storage local-lvm
qm restore ${N}02 pbs-lab:backup/vm/${N}02/<timestamp> --storage local-lvm
pct restore ${N}11 pbs-lab:backup/ct/${N}11/<timestamp> --storage local-lvm
qm list ; pct list
```

✅ Vous venez d'utiliser vos sauvegardes pour de vrai. C'est la seule preuve qui compte.

---

## 6. Déployer Ceph 🐙

### 6.1 Installer les paquets — sur les 6 nœuds

🌐 `pveN → Ceph` : un assistant s'ouvre au premier accès. Ou en CLI :

```bash
pveceph install --repository no-subscription
pveceph --version 2>/dev/null; ceph --version
```

> `pveceph install` propose plusieurs versions (`--version squid|tentacle`). Prenez
> **la même sur les six nœuds** — le formateur annonce laquelle.

### 6.2 Initialiser — sur `pve1` uniquement

```bash
pveceph init --network 192.168.50.0/24 --size 3 --min_size 2
cat /etc/pve/ceph.conf
cat /etc/ceph/ceph.conf     # lien symbolique vers /etc/pve/ceph.conf
```

🧠 **`--network`** définit le réseau *public* de Ceph (clients ↔ OSD).
`--cluster-network` permettrait d'isoler la réplication OSD ↔ OSD sur un second
réseau : **c'est ce qu'on ferait en production**, et c'est le premier réglage à
réclamer quand on dimensionne un vrai cluster. Ici, on n'a qu'un LAN.

### 6.3 Les monitors — 3 suffisent

```bash
# sur pve1 (le premier est créé par pveceph init sur certaines versions)
pveceph mon create

# sur pve2 puis pve3
pveceph mon create
```

```bash
ceph -s
pveceph status
```

🪤 **Toujours un nombre impair de monitors** (3 ou 5), pour la même raison que le
quorum Corosync. Trois monitors sur six nœuds, c'est le bon choix : cinq
consommeraient de la ressource pour rien.

### 6.4 Les managers

```bash
# sur pve1
pveceph mgr create
# sur pve2 — il sera en veille (standby)
pveceph mgr create

ceph -s | grep -A2 services
```

### 6.5 Les OSD — ⭐ le moment où l'interface web ne suffit pas

🌐 `pveN → Ceph → OSD → Create: OSD` : la liste déroulante **est vide**.
L'interface ne propose que les disques entiers non utilisés, et votre volume LVM n'en
est pas un. C'est normal, et c'est pour cela qu'on passe en CLI.

**Sur chaque nœud** :

```bash
ls -l /dev/pve/ceph-osd
pveceph osd create /dev/pve/ceph-osd
```

Si `pveceph` refuse le volume logique, utilisez la commande Ceph native — c'est elle
que `pveceph` appelle en interne :

```bash
# Récupérer la clé de bootstrap (ceph-volume l'exige à cet emplacement)
mkdir -p /var/lib/ceph/bootstrap-osd
ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
chown -R ceph:ceph /var/lib/ceph/bootstrap-osd

# Créer l'OSD sur le volume logique  (notation VG/LV)
ceph-volume lvm create --data pve/ceph-osd --bluestore

# Vérifier et activer
ceph-volume lvm list
ceph-volume lvm activate --all
systemctl status ceph-osd@* --no-pager | head -10
```

🧠 **Ce que `ceph-volume` fait** : il crée un LV supplémentaire pour les métadonnées
BlueStore, tatoue des *tags* LVM sur votre volume (`ceph.osd_id`, `ceph.osd_fsid`,
`ceph.cluster_fsid`) et génère l'unité systemd d'activation. Ces tags sont ce qui
permet à Ceph de retrouver ses OSD au démarrage, même si les noms de périphériques
changent.

```bash
lvs -o lv_name,vg_name,lv_tags pve | tr ',' '\n' | grep ceph | head
```

### 6.6 Vérifier le cluster

```bash
ceph -s
ceph osd tree
ceph osd df
ceph health detail
```

Attendu, avec les six OSD :

```
  cluster:
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum pve1,pve2,pve3
    mgr: pve1(active), standbys: pve2
    osd: 6 osds: 6 up, 6 in
```

```
ID  CLASS  WEIGHT   TYPE NAME       STATUS
-1         0.70319  root default
-3         0.11719      host pve1
 0    hdd  0.11719          osd.0       up
-5         0.11719      host pve2
 1    hdd  0.11719          osd.1       up
 ...
```

🎯 **`host pve1`, `host pve2`…** : CRUSH sait que chaque OSD est sur une machine
différente. C'est ce qui lui permet de garantir que les trois copies d'un bloc ne se
retrouvent jamais sur le même nœud. Cette hiérarchie s'appelle la **CRUSH map**, et
elle peut décrire des racks, des salles, des datacenters.

---

## 7. Brider la reconstruction — à faire tout de suite ⚠️

Sur un lien 1 Gb/s partagé avec Corosync, un rééquilibrage non bridé **fera perdre le
quorum du cluster Proxmox**. Ce n'est pas théorique.

```bash
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 2
ceph config set osd osd_recovery_op_priority 1
ceph config set osd osd_recovery_sleep 0.1
ceph config dump | grep -E 'backfill|recovery'
```

🧠 On dit à Ceph : « reconstruis lentement, la disponibilité du cluster passe avant la
vitesse de retour à la redondance ». Sur un vrai réseau 25 Gb/s dédié, on ferait
exactement l'inverse.

---

## 8. Créer le pool et le stockage 🏊

```bash
pveceph pool create vm-store \
  --size 3 --min_size 2 \
  --pg_autoscale_mode on \
  --application rbd \
  --add_storages 1

pveceph pool ls
ceph osd pool ls detail
pvesm status
```

🧠 **`--add_storages 1`** déclare automatiquement le stockage Proxmox correspondant —
répliqué sur les six nœuds par pmxcfs. Une seule commande, et les six nœuds voient
`vm-store`.

```bash
cat /etc/pve/storage.cfg | grep -A6 rbd
```

🧠 **`--pg_autoscale_mode on`** : Ceph ajuste seul le nombre de *placement groups* selon
le volume de données. Historiquement il fallait calculer `pg_num` à la main — c'était
la principale source d'erreurs de dimensionnement. Laissez l'autoscaler faire.

### CephFS — pour les ISO, templates et snippets

Un pool RBD ne stocke que des disques bloc. Pour des **fichiers** partagés, il faut
CephFS.

```bash
# Un serveur de métadonnées sur 2 ou 3 nœuds
pveceph mds create          # sur pve1
pveceph mds create          # sur pve2

# Le système de fichiers
pveceph fs create --name cephfs --add-storage 1

pvesm status
df -h /mnt/pve/cephfs
ceph fs status
```

✅ Vous avez maintenant, partagé sur les six nœuds :

| Stockage | Type | Contenu |
|---|---|---|
| `vm-store` | `rbd` | disques de VM et de conteneurs |
| `cephfs` | `cephfs` | ISO, templates, snippets, sauvegardes |
| `local-lvm` | `lvmthin` | disques locaux (rapides, non partagés) |
| `nfs-eN` | `nfs` | le partage de votre poste (TP 14) |
| `pbs-lab` | `pbs` | sauvegardes (TP 15) |

---

## 9. L'utiliser 🚀

```bash
N=3
# Déplacer un disque vers Ceph, à chaud
qm move-disk ${N}01 scsi0 vm-store --delete 1
qm config ${N}01 | grep scsi0
rbd -p vm-store ls
rbd -p vm-store info vm-${N}01-disk-0
```

```bash
N=3     # ⚠ VOTRE numéro d'élève
# Créer directement sur Ceph
qm clone ${N}90 ${N}70 --name ceph-vm-e$N --pool eleve$N
qm move-disk ${N}70 scsi0 vm-store --delete 1
qm set ${N}70 --net0 virtio,bridge=vprod,firewall=1,mtu=1 --ipconfig0 ip=dhcp
qm start ${N}70
```

```bash
# Copier les ISO sur CephFS : une seule copie pour tout le cluster
cp /mnt/pve/nfs-e3/template/iso/debian-13*.iso /mnt/pve/cephfs/template/iso/
pvesm list cephfs
```

### Observer la répartition

```bash
ceph osd map vm-store vm-301-disk-0
ceph pg ls-by-pool vm-store | head -5
ceph df
ceph osd df
```

🎯 `ceph osd map` vous dit **exactement** sur quels OSD un objet est stocké. Regardez :
trois OSD, sur trois nœuds différents. C'est CRUSH au travail.

---

## 10. Le test qui justifie tout : tuer un nœud 🔥

**Avec l'accord du formateur.** Choisissez un nœud qui n'est ni `pve1` (exit node EVPN
et hôte de PBS) ni un monitor si vous voulez rester simple.

```bash
# Terminal 1 — surveiller Ceph
watch -n2 'ceph -s; echo; ceph osd tree | head -20'

# Terminal 2 — une VM sur Ceph, avec des écritures continues
ssh -J root@192.168.50.11 eleve@10.60.10.<ip> \
  'while true; do dd if=/dev/urandom of=/tmp/t bs=1M count=20 2>/dev/null; sync; date; done'
```

Coupez l'alimentation du nœud cible.

### Chronologie attendue

```
   T+0 s      le nœud disparaît
   T+~20 s    ceph -s : « 1 osds down », HEALTH_WARN
              ⭐ la VM CONTINUE D'ÉCRIRE : il reste 2 copies sur 3
   T+~10 min  Ceph déclare l'OSD « out » et commence à reconstruire
              la 3e copie ailleurs (HEALTH_WARN, degraded → recovering)
   T+…        HEALTH_OK, redondance rétablie sans le nœud mort
```

```bash
ceph -s
ceph osd tree
ceph health detail
```

🎯 **Comparez avec le TP 14** : quand vous avez coupé le NFS, tout a gelé
immédiatement. Là, un nœud entier disparaît et le service ne s'interrompt pas une
seconde. C'est ça, la différence entre du stockage centralisé et du stockage distribué.

Rebranchez le nœud :

```bash
ceph -s                       # l'OSD revient « up » et « in »
ceph osd tree
watch -n2 'ceph -s | grep -E "recovery|degraded|misplaced"'
```

Ceph rééquilibre tout seul. Vous n'avez rien à faire.

---

## 11. Exploitation courante 🔧

```bash
# État
ceph -s
ceph health detail
ceph df                        # espace, par pool
ceph osd df                    # remplissage, par OSD
ceph osd perf                  # latences
ceph -w                        # journal en direct

# OSD
ceph osd tree
ceph osd out <id>              # sortir du cluster (les données migrent)
ceph osd in <id>
pveceph osd destroy <id> --cleanup

# Maintenance planifiée : suspendre la reconstruction
ceph osd set noout
# ... intervention sur un nœud ...
ceph osd unset noout

# Pools
ceph osd pool ls detail
ceph osd pool set vm-store size 3
pveceph pool destroy vm-store --remove_storages 1

# Images RBD
rbd -p vm-store ls -l
rbd -p vm-store du
```

### Les avertissements que vous verrez 🪤

| Message | Signification | Réaction |
|---|---|---|
| `POOL_NO_REDUNDANCY` | `size 1` sur un pool | corriger immédiatement |
| `OSD_NEARFULL` (85 %) | un OSD se remplit | ⚠️ Ceph bloque **tout** à 95 % |
| `PG_AVAILABILITY` | des PG sans OSD disponible | vérifier les OSD `down` |
| `POOL_TOO_FEW_PGS` | pas assez de PG | l'autoscaler s'en occupe |
| `MON_CLOCK_SKEW` | horloges désynchronisées | ⭐ vérifier NTP, Ceph y est très sensible |
| `SLOW_OPS` | opérations lentes | réseau ou disque saturés — notre cas |

🚨 **`OSD_FULL` à 95 % arrête toutes les écritures du cluster.** Surveillez `ceph df`
comme vous surveillez `df -h`. Un Ceph plein, c'est une production à l'arrêt.

---

## 12. Comparaison finale des stockages 📊

| | `local-lvm` | `nfs-eN` | **`vm-store` (Ceph)** |
|---|---|---|---|
| Performance | ⭐⭐⭐ | ⭐ | ⭐⭐ (⭐⭐⭐ avec du 10 G) |
| Partagé | ❌ | ✅ | ✅ |
| Snapshots | ✅ | ✅ (qcow2) | ✅ |
| Migration à chaud | copie du disque | rapide | **rapide** |
| Haute disponibilité | ❌ | ⚠️ avec SPOF | ✅ |
| Tolère la perte d'un nœud | ❌ | ❌ | ✅ |
| Extensible à chaud | ❌ | ❌ | ✅ ajoutez un OSD |
| Complexité | ★ | ★★ | ★★★★ |
| Nœuds minimum | 1 | 1 | **3** |

🧠 **Quand choisir quoi ?**
- **1 à 2 nœuds** → local + sauvegardes. Ceph n'a aucun sens.
- **3 nœuds et plus, budget réseau** → Ceph, sans hésiter.
- **Une baie/NAS existant** → NFS ou iSCSI, plus simple à exploiter.
- **Toujours, quel que soit le choix** → des sauvegardes. Ceph n'est pas une
  sauvegarde : il réplique fidèlement vos suppressions.

---

## 13. Dépannage 🔧

| Symptôme | Cause | Solution |
|---|---|---|
| L'UI ne propose aucun disque pour l'OSD | volume LVM, pas disque entier | CLI : `pveceph osd create /dev/pve/ceph-osd` ou `ceph-volume lvm create` |
| `lvreduce` refuse | thin pool non réductible | chemin B du §5 |
| `Device /dev/... is in use` | reste d'un usage précédent | `ceph-volume lvm zap /dev/pve/ceph-osd --destroy` |
| `ceph-volume` : `unable to find keyring` | clé bootstrap absente | `ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring` |
| OSD créé mais `down` | service non activé | `ceph-volume lvm activate --all` puis `systemctl status ceph-osd@<id>` |
| `MON_CLOCK_SKEW` | dérive d'horloge | `timedatectl status` sur tous les nœuds |
| `HEALTH_WARN` persistant après une panne | reconstruction en cours | `ceph -w`, patience ; vérifier les réglages du §7 |
| Le cluster Proxmox devient instable | Ceph sature le lien | brider (§7), `ceph osd set noout` pendant l'intervention |
| Corosync perd le quorum pendant un backfill | réseau partagé | c'est LA limite du lab — un lien dédié en production |

```bash
# Le trio de diagnostic
ceph -s
ceph health detail
journalctl -u ceph-osd@<id> -n 50 --no-pager

# Repartir de zéro (⚠ détruit toutes les données Ceph)
pveceph purge --crash --logs
ceph-volume lvm zap /dev/pve/ceph-osd --destroy
```

---

## ✅ Checklist de validation

- [ ] Je sais dire pourquoi un thin pool LVM ne peut pas être réduit
- [ ] J'ai libéré de l'espace dans le VG `pve` (chemin A, B ou C)
- [ ] `lvs pve` montre un volume `ceph-osd`
- [ ] Ceph est installé sur les 6 nœuds, même version
- [ ] `ceph -s` : `HEALTH_OK`, 3 monitors en quorum, 2 managers
- [ ] `ceph osd tree` montre **6 OSD, sur 6 hosts distincts** 🎯
- [ ] Les réglages de bridage de la reconstruction sont appliqués (§7)
- [ ] Le pool `vm-store` existe en `size 3 / min_size 2`
- [ ] Le stockage `vm-store` est visible depuis les 6 nœuds
- [ ] CephFS est monté et contient mes ISO
- [ ] Un disque de VM a été déplacé sur Ceph, la VM fonctionne
- [ ] `ceph osd map` me montre les 3 OSD qui portent un objet
- [ ] **J'ai coupé un nœud et la VM a continué d'écrire** 🎯
- [ ] Ceph a reconstruit seul, et est revenu en `HEALTH_OK`
- [ ] Je sais citer trois raisons pour lesquelles ce lab n'est pas dimensionné pour Ceph

---

## 🎁 Bonus

1. **Erasure coding** : créez un pool en EC (`--erasure-coding k=4,m=2`) et comparez
   l'espace utile avec la réplication ×3. Pourquoi ne l'utilise-t-on pas pour des
   disques de VM ? (Indice : la pénalité en écriture aléatoire.)
2. **La CRUSH map** : `ceph osd getcrushmap -o /tmp/cm && crushtool -d /tmp/cm`.
   Lisez-la. Ajoutez un niveau `rack` et déplacez-y trois hosts. Vous venez de décrire
   une tolérance à la panne d'une baie entière.
3. **Mesurer** : `rados bench -p vm-store 30 write --no-cleanup` puis `rados bench -p
   vm-store 30 rand`. Comparez avec les débits NFS du TP 14 et avec `local-lvm`.
   Documentez : c'est ce chiffre que votre client vous demandera.
4. **Le tableau de bord Ceph** : `ceph mgr module enable dashboard`. Comparez avec
   l'interface Proxmox. Qu'apporte-t-il de plus ?
5. **Deux nœuds en moins** : coupez-en deux d'un coup. Le pool passe en lecture seule
   (`min_size 2` non satisfait). Vérifiez qu'aucune donnée n'est perdue au retour, et
   expliquez pourquoi ce comportement est préférable à laisser écrire.

➡️ Suite : [TP 19 — Migration à chaud et Haute Disponibilité](19-migration-ha.md)
