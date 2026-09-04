# TP 18 — Cluster Ceph intégré à Proxmox 🐙

⏱️ **1 h 45** · Jour 4

Objectif : monter un stockage distribué à trois copies, sans point de défaillance
unique, sur les six nœuds. Pour cela, faire de la place sur le disque système en
manipulant LVM à la main : l'interface web ne sait pas le faire.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pveceph.html>
📖 Wiki : <https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster>

---

## 1. Ce que Ceph résout 🧠

Au TP 14, votre NFS marchait jusqu'à ce que vous coupiez le serveur : un **point de
défaillance unique**.

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

   Le PC tombe → TOUT gèle              1 nœud tombe → ça continue
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
n'est acceptée que si au moins deux sont confirmées.

Traduction opérationnelle :

| Nœuds perdus (sur 6) | Données | Service |
|---|---|---|
| **1** | intactes (2 copies restantes) | ✅ continu, `HEALTH_WARN`, backfill automatique |
| **2** | intactes (au moins 1 copie) | ⚠️ **partiellement bloqué** |
| **3** | ⚠️ perte possible | ❌ |

🪤 **Le cas « 2 nœuds » est le plus mal compris.** « size 3 donc je survis à 2 pannes »
est vrai pour les *données*, faux pour le *service*.

Un PG n'a que 3 réplicas, sur 3 hôtes tirés par CRUSH parmi les 6. Si les deux hôtes
tombés font partie de ces 3, le PG descend à **1 copie — sous `min_size 2`** : Ceph
refuse alors les E/S sur ce PG pour ne pas risquer une divergence. Les autres PG
continuent normalement.

```
   PG dont les 3 réplicas sont sur  pve1 pve2 pve3   → pve1+pve2 tombent → 1 copie → ✋ E/S bloquées
   PG dont les 3 réplicas sont sur  pve3 pve4 pve5   → pve1+pve2 tombent → 3 copies → ✅ rien à signaler
```

Avec 6 hôtes et 3 réplicas, **environ un PG sur cinq** est concerné (les combinaisons
qui contiennent les 2 hôtes tombés : `C(4,1) / C(6,3)` = 4/20). Le volume redevient
pleinement disponible une fois le *backfill* terminé sur les 4 nœuds restants.

👉 **`size` protège les données, `min_size` protège la cohérence, et c'est `min_size`
qui décide si vous êtes encore en service.**

---

## 2. ⚠️ Ce lab n'est pas une architecture Ceph recommandable

À dire au client.

| Recommandation officielle | Notre lab | Conséquence |
|---|---|---|
| **≥ 10 Gb/s dédiés** à Ceph | 1 Gb/s, partagé avec tout | Performances faibles ; risque pour Corosync |
| Réseau **public** et **cluster** séparés | un seul LAN plat | Le trafic de réplication écrase le reste |
| Corosync sur un lien **dédié** | le même LAN | Un *backfill* Ceph peut déstabiliser le quorum |
| **Un disque entier** par OSD, en SSD | un volume LVM sur le disque système | I/O système et Ceph en concurrence |
| ≥ 8 Gio de RAM **par OSD** | ce qu'il reste | Ceph consommera beaucoup |
| Pas de RAID matériel, HBA direct | selon le matériel | — |

🎯 **Ce qui reste transposable** : le déploiement, la manipulation LVM, le comportement
de CRUSH, la reconstruction après panne, le monitoring, le raisonnement.

⚠️ Limitez le débit de reconstruction (§7), sinon un rééquilibrage sature le lien et fait
perdre le quorum Corosync.

---

## 3. Le problème du disque : où mettre l'OSD ? 🧩

Un OSD a besoin d'un **périphérique bloc dédié**. Ceph accepte trois formes :
un disque entier, une partition, ou un **volume logique LVM**.

L'interface web ne propose que les **disques entiers non utilisés**, et votre disque
unique est entièrement occupé :

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
   │    (vous avez réduit maxvz à l'installation, TP 01 §3.1 bis) │
   ├─────────────────────────────────────────────────────────────┤
   │ ② VG_FREE ≈ 0              → chemin B : recréer le thin pool │
   │    (le cas par défaut)        ⚠ destructif, sauvegarde requise│
   ├─────────────────────────────────────────────────────────────┤
   │ ③ Un second disque libre   → chemin C : pveceph osd create   │
   │                               /dev/sdb 🎉                    │
   └─────────────────────────────────────────────────────────────┘
```

### 🪤 Pourquoi ne pas simplement réduire le thin pool ?

Essayez :

```bash
lvreduce -L -60G pve/data
```

```
  Thin pool volumes pve/data_tdata cannot be reduced in size yet.
```

**LVM ne sait pas réduire un thin pool.** Limite de conception, pas bug : les blocs d'un
pool thin ne sont pas alloués linéairement, il peut y avoir des données tout à la fin,
et dm-thin n'a aucun mécanisme pour les défragmenter vers le début. Des outils tiers
(`thin_shrink`) réécrivent les métadonnées ; on ne joue pas à ça sur des données réelles.

**La seule voie propre : sauvegarder, détruire, recréer plus petit, restaurer.** D'où le
TP 15 (PBS) avant celui-ci.

> 💡 Si vous avez réglé `maxvz` en réinstallant votre nœud au TP 16, vous êtes en
> **chemin A** : trois commandes. Le chemin B reste documenté : c'est le cas d'une machine
> installée par quelqu'un d'autre.

---

## 4. Chemin A — il reste de la place dans le VG 🎉

> 💡 `lab/scripts/ceph-prep-lvm.sh --check` fait le diagnostic du §3 et indique le chemin
> à suivre. Lancez-le d'abord.

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

**Destructif.** Lisez tout avant de taper.

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
# Tous les guests de CE nœud, vers PBS
vzdump --all --storage pbs-lab --mode snapshot --compress zstd

pvesm list pbs-lab
```

🌐 Sur PBS : `Datastore → lab-store → lab → Verify`.

🚨 **Ne continuez que si la vérification est verte.** Vous allez effacer les originaux.

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
lvremove pve/vm-<vmid>-disk-0     # ex. — un par un, en connaissance de cause
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

🪤 **Laissez 5 à 10 % du VG libres.** LVM en a besoin pour les snapshots et les
métadonnées ; un VG à 100 % interdit toute manœuvre future. Pas de `-l 100%FREE`.

```bash
# 4. Réactiver le stockage
pvesm set local-lvm --disable 0
pvesm status
```

> 💡 Les étapes 5.3 sont scriptées, avec garde-fous :
> ```bash
> bash /root/formation/lab/scripts/ceph-prep-lvm.sh \
>      --size 120G --recreate-thinpool 200G --i-know
> ```
> Le script refuse s'il reste une VM, un conteneur ou un volume dans le pool. Lisez-le
> avant de l'exécuter.

### 5.4 Restaurer les guests

```bash
pvesm list pbs-lab                  # les sauvegardes de vos guests, avec leur VMID
qm restore <vmid>  pbs-lab:backup/vm/<vmid>/<timestamp> --storage local-lvm
pct restore <ctid> pbs-lab:backup/ct/<ctid>/<timestamp> --storage local-lvm
qm list ; pct list
```

---

## 6. Déployer Ceph 🐙

### 6.1 Installer les paquets — sur les 6 nœuds

🌐 `votre nœud → Ceph` : un assistant s'ouvre au premier accès. Ou en CLI :

```bash
pveceph install --repository no-subscription
pveceph --version 2>/dev/null; ceph --version
```

> `pveceph install` propose plusieurs versions (`--version squid|tentacle`). Prenez
> **la même sur les six nœuds** — le formateur annonce laquelle.

### 6.2 Initialiser — sur `pve1` uniquement

```bash
pveceph init --network 172.30.30.0/24 --size 3 --min_size 2
cat /etc/pve/ceph.conf
cat /etc/ceph/ceph.conf     # lien symbolique vers /etc/pve/ceph.conf
```

🧠 **`--network`** définit le réseau *public* de Ceph (clients ↔ OSD).
`--cluster-network` isolerait la réplication OSD ↔ OSD sur un second réseau : le premier
réglage à réclamer en production. Ici, on n'a qu'un LAN.

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
quorum Corosync. Trois sur six nœuds suffisent ; cinq consommeraient pour rien.

### 6.4 Les managers

```bash
# sur pve1
pveceph mgr create
# sur pve2 — il sera en veille (standby)
pveceph mgr create

ceph -s | grep -A2 services
```

### 6.5 Les OSD — ⭐ le moment où l'interface web ne suffit pas

🌐 `votre nœud → Ceph → OSD → Create: OSD` : la liste déroulante **est vide**.
L'interface ne propose que les disques entiers non utilisés, et votre volume LVM n'en
est pas un. D'où la CLI.

**Sur chaque nœud** :

```bash
ls -l /dev/pve/ceph-osd
pveceph osd create /dev/pve/ceph-osd
```

Si `pveceph` refuse le volume logique, utilisez la commande Ceph native, celle que
`pveceph` appelle en interne :

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

🧠 **Ce que fait `ceph-volume`** : un LV supplémentaire pour les métadonnées BlueStore,
des *tags* LVM sur votre volume (`ceph.osd_id`, `ceph.osd_fsid`, `ceph.cluster_fsid`),
et l'unité systemd d'activation. Ces tags permettent à Ceph de retrouver ses OSD au
démarrage, même si les noms de périphériques changent.

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
différente, et garantit que les trois copies d'un bloc ne sont jamais sur le même nœud.
Cette hiérarchie, la **CRUSH map**, peut décrire des racks, des salles, des datacenters.

---

## 7. Brider la reconstruction — à faire tout de suite ⚠️

Sur un lien 1 Gb/s partagé avec Corosync, un rééquilibrage non bridé **fait perdre le
quorum du cluster Proxmox**.

```bash
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 2
ceph config set osd osd_recovery_op_priority 1
ceph config set osd osd_recovery_sleep 0.1
ceph config dump | grep -E 'backfill|recovery'
```

🧠 On dit à Ceph : « reconstruis lentement, la disponibilité passe avant la vitesse de
retour à la redondance ». Sur un réseau 25 Gb/s dédié, on ferait l'inverse.

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

🧠 **`--add_storages 1`** déclare le stockage Proxmox correspondant, répliqué sur les
six nœuds par pmxcfs.

```bash
cat /etc/pve/storage.cfg | grep -A6 rbd
```

🧠 **`--pg_autoscale_mode on`** : Ceph ajuste seul le nombre de *placement groups*.
Calculer `pg_num` à la main était la principale source d'erreurs de dimensionnement.

### CephFS — pour les ISO, templates et snippets

Un pool RBD ne stocke que des disques bloc. Pour des **fichiers** partagés : CephFS.

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

✅ Partagé sur les six nœuds :

| Stockage | Type | Contenu |
|---|---|---|
| `vm-store` | `rbd` | disques de VM et de conteneurs |
| `cephfs` | `cephfs` | ISO, templates, snippets, sauvegardes |
| `local-lvm` | `lvmthin` | disques locaux (rapides, non partagés) |
| `nfs-<nœud>` | `nfs` | le partage de votre poste (TP 14, redéclaré au TP 16) |
| `pbs-lab` | `pbs` | sauvegardes (TP 15) |

---

## 9. L'utiliser 🚀

```bash
VMID=$(qm list | awk '/evpn-prod/{print $1}')     # votre VM du TP 17 — depuis le nœud où elle tourne
# Déplacer un disque vers Ceph, à chaud
qm move-disk $VMID scsi0 vm-store --delete 1
qm config $VMID | grep scsi0
rbd -p vm-store ls
rbd -p vm-store info vm-$VMID-disk-0
```

```bash
# Créer directement sur Ceph
TPL=$(qm list | awk '/tpl-debian13/{print $1}')
NEW=$(pvesh get /cluster/nextid)
qm clone $TPL $NEW --name ceph-vm-$(hostname) --pool lab --full 1
qm move-disk $NEW scsi0 vm-store --delete 1
qm set $NEW --net0 virtio,bridge=vprod,firewall=1,mtu=1 --ipconfig0 ip=dhcp
qm start $NEW
```

```bash
# Copier les ISO sur CephFS : une seule copie pour tout le cluster
cp /mnt/pve/nfs-$(hostname)/template/iso/debian-13*.iso /mnt/pve/cephfs/template/iso/
pvesm list cephfs
```

### Observer la répartition

```bash
ceph osd map vm-store vm-$VMID-disk-0
ceph pg ls-by-pool vm-store | head -5
ceph df
ceph osd df
```

🎯 `ceph osd map` donne les OSD qui portent un objet : trois, sur trois nœuds différents.

---

## 10. Le test qui justifie tout : tuer un nœud 🔥

**Avec l'accord du formateur.** Choisissez un nœud qui n'est ni `pve1` (exit node EVPN
et hôte de PBS) ni un monitor.

```bash
# Terminal 1 — surveiller Ceph
watch -n2 'ceph -s; echo; ceph osd tree | head -20'

# Terminal 2 — une VM sur Ceph, avec des écritures continues
ssh eleve@10.60.10.<ip> \
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

🎯 Au TP 14, couper le NFS a tout gelé. Ici un nœud entier disparaît et le service
continue : la différence entre stockage centralisé et distribué.

Rebranchez le nœud :

```bash
ceph -s                       # l'OSD revient « up » et « in »
ceph osd tree
watch -n2 'ceph -s | grep -E "recovery|degraded|misplaced"'
```

Ceph rééquilibre seul.

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
comme `df -h`.

---

## 12. Comparaison finale des stockages 📊

| | `local-lvm` | `nfs-<nœud>` | **`vm-store` (Ceph)** |
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
- **Dans tous les cas** → des sauvegardes. Ceph réplique fidèlement vos suppressions.

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
   Lisez-la. Ajoutez un niveau `rack` et déplacez-y trois hosts : vous décrivez une
   tolérance à la panne d'une baie entière.
3. **Mesurer** : `rados bench -p vm-store 30 write --no-cleanup` puis `rados bench -p
   vm-store 30 rand`. Comparez avec les débits NFS du TP 14 et avec `local-lvm`, et
   documentez : c'est le chiffre que le client demandera.
4. **Le tableau de bord Ceph** : `ceph mgr module enable dashboard`. Comparez avec
   l'interface Proxmox. Qu'apporte-t-il de plus ?
5. **Deux nœuds en moins** : coupez-en deux d'un coup. Le pool passe en lecture seule
   (`min_size 2` non satisfait). Vérifiez qu'aucune donnée n'est perdue au retour, et
   expliquez pourquoi ce comportement est préférable à laisser écrire.

➡️ Suite : [TP 19 — Migration à chaud et Haute Disponibilité](19-migration-ha.md)
