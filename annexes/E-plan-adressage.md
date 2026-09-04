# Annexe E — Plan d'adressage, VMID et tags 📇

En cas de doute, ce document fait foi.

---

## 🌍 Réseau physique — LAN salle `172.30.30.0/24`

| Élément | Adresse | Note |
|---|---|---|
| Passerelle / Internet | `172.30.30.2` | box, aucun accès admin |
| DNS | `1.1.1.1` (primaire) et `8.8.8.8` (secours) | résolveurs publics |
| **Nœud pve1** | `172.30.30.151` | **exit node primaire** · héberge PBS et Pulse · crée le cluster · MON + MGR Ceph |
| **Nœud pve2** | `172.30.30.152` | exit node secondaire · MON + MGR Ceph |
| **Nœud pve3** | `172.30.30.153` | MON Ceph |
| **Nœud pve4** | `172.30.30.154` | |
| **Nœud pve5** | `172.30.30.155` | |
| **Nœud pve6** | `172.30.30.156` | |
| PC Ubuntu (un par stagiaire) | **`$PC`** | postes de pilotage · adresse relevée sur le poste |
| **Serveur NFS de chaque stagiaire** | son **PC Ubuntu**, donc `$PC` | TP 14 |
| **VM `pbs`** | **`$PBS`** | TP 15 : une par nœud · TP 16 : celle de la salle sur **pve1** · UI sur `:8007` |
| **CT `pulse`** | **`$PULSE`** | TP 20 · sur pve1 · UI sur `:7655` |
| VM du jour 1 sur `vmbr0` | **DHCP de la salle** | on relève l'IP obtenue |
| Adresses statiques sur `vmbr0` | `172.30.30.200` → `.250` | attribuées par le formateur : PBS, Pulse, secours sans DHCP |

### Les nœuds : deux vies

| | Jours 1-3 | Jour 4 (après réinstallation, TP 16) |
|---|---|---|
| Hostname | **`pve`** (`pve.lab.local`), le même pour tous | `pve1` … `pve6` selon le tableau ci-dessus |
| IP | `$PVE` — celle attribuée par le formateur, dans `.151`–`.156` | **la même** |
| Contexte | nœud isolé, aucun cluster | cluster à six |

🧠 Chaque stagiaire est **seul** sur son nœud pendant trois jours, et tout est
réinstallé avant la mise en cluster : VMID, réseaux SDN et noms sont **identiques pour
tout le monde**. Seules quatre adresses varient : `$PVE`, `$PC`, `$PBS`, `$PULSE`.

> ⚠️ **Ces quatre adresses ne sont pas figées dans ce document** : seule la plage
> `.151`–`.156` des nœuds l'est. Relevez l'adresse de votre poste avec `hostname -I`,
> notez celle de votre nœud quand le formateur vous l'attribue, et celles de PBS et
> Pulse au moment où elles sont fixées (TP 15/16 et TP 20).

> 🧠 Le serveur NFS n'est **pas** une VM : c'est le PC Ubuntu de chaque stagiaire, qui
> exporte `/srv/nfs` vers son propre nœud (TP 14).

### Les VM du jour 1 (sur `vmbr0`, avant le passage au SDN)

Elles sont en **DHCP** sur le LAN de la salle. On relève l'adresse obtenue :

| Machine | VMID | Où lire l'IP |
|---|---|---|
| `srv01` (Debian ISO) | `101` | Summary de la VM (agent QEMU) · `qm agent 101 network-get-interfaces` |
| `ct-alpine` | `111` | `pct exec 111 -- ip -4 -br a show eth0` |
| `win01` (Windows) | `102` | Summary de la VM · `ipconfig` |
| `ct-rocky` | `112` | `pct exec 112 -- ip -4 -br a show eth0` |

Sans DHCP dans la salle : le formateur attribue des adresses dans `.200`–`.250`.

⚠️ À partir du TP 08, ces machines déménagent dans les VNets SDN.

---

## 🕸️ Réseaux SDN — jour 2 (nœud isolé, zones `Simple`)

**Les mêmes pour tout le monde** : ces réseaux vivent derrière le NAT de chaque nœud,
comme six réseaux domestiques en `192.168.1.0/24`.

| VNet | Zone | Subnet | Gateway | DHCP | SNAT | Créé au |
|---|---|---|---|---|---|---|
| `vint` | `zint` | `10.10.10.0/24` | `10.10.10.1` | `.100`–`.200` | ✅ | TP 08 |
| `vdmz` | `zdmz` | `10.10.20.0/24` | `10.10.20.1` | `.100`–`.200` | ✅ | TP 08 |
| `vsrv` | `zsrv` | `10.10.30.0/24` | `10.10.30.1` | `.100`–`.200` | ✅ | TP 12 (Terraform) |
| *(temporaire)* `vmbr1` | — | `10.10.99.0/24` | `10.10.99.1` | `.100`–`.200` | ✅ | TP 07, supprimé ensuite |

Adresse fixe notable : `cloud01` (TP 10, VMID 120) en `10.10.10.50`.

Depuis le PC, ces réseaux se joignent **directement**, par une route statique posée au
TP 07 : `sudo ip route add 10.10.0.0/16 via $PVE`. Au jour 4, même principe pour l'EVPN
via l'exit node : `sudo ip route add 10.60.0.0/16 via 172.30.30.151`. **Aucun rebond
SSH** dans cette formation.

---

## 🌐 Réseaux SDN — jour 4 (cluster, zone `EVPN`)

**Partagés par tout le monde.** L'IPAM cluster garantit l'unicité des adresses.

| Objet | Valeur |
|---|---|
| Contrôleur | `evpnctl` · ASN `65000` · peers = les 6 nœuds |
| Zone | `zevpn` · VRF VNI `10000` · **MTU 1450** |
| Exit nodes | `pve1`, `pve2` — **primaire : `pve1`** |
| Options | `advertise-subnets 1`, `exitnodes-local-routing 1` |

| VNet | VNI | Subnet | Gateway | DHCP | SNAT | Usage |
|---|---|---|---|---|---|---|
| `vprod` | `11010` | `10.60.10.0/24` | `10.60.10.1` | `.100`–`.240` | ✅ | Production |
| `vpub` | `11020` | `10.60.20.0/24` | `10.60.20.1` | `.100`–`.240` | ✅ | DMZ publique |
| `vdb` | `11030` | `10.60.30.0/24` | `10.60.30.1` | `.100`–`.240` | ❌ | Bases, **sans Internet** |

**Ports à laisser passer entre nœuds** :

| Port | Protocole | Usage |
|---|---|---|
| `4789` | UDP | VXLAN — **le grand oublié** |
| `179` | TCP | BGP |
| `5405`–`5412` | UDP | Corosync |
| `8006` | TCP | interface web PVE |
| `8007` | TCP | interface web PBS |
| `2049` | TCP | NFS v4 (nœud → PC du stagiaire) |
| `6789`, `3300` | TCP | Ceph monitors |
| `6800`–`7300` | TCP | Ceph OSD et MDS |
| `3128` | TCP | proxy SPICE |
| `5900`–`5999` | TCP | consoles VNC |
| `60000`–`60050` | TCP | migration de VM |

---

## 🔢 Plan de VMID

### Jours 1-3 : fixes, identiques pour tous

| VMID | Machine | TP |
|---|---|---|
| `101` | `srv01` — Debian, ISO | 03 |
| `102` | `win01` — Windows Server 2025 | 04 |
| `103` | VM jetable — clone de test de `srv01`, détruit aussitôt | 03 |
| `111` | `ct-alpine` | 05 |
| `112` | `ct-rocky` | 05 |
| `113`–`115` | conteneurs jetables (`ct-restore`, `ct-tpl`, `ct-clone`) | 05 |
| `119` | `ct-nat` — test sur `vmbr1` | 07 |
| `120` | `cloud01` — clone cloud-init **manuel**, IP fixe `10.10.10.50` | 10 |
| *auto* | `web01`, `app01`, `db01`, `ct-cache` (stacks Terraform 01 et 02) | 11 |
| *auto* | `mon01`, `log01` (stack Terraform 03) | 12 |
| `180`–`189` | bonus : dix Alpine | 05 |
| `190` | `tpl-debian13` | 10 |
| `191` | `tpl-ubuntu2604` | 10 |
| `192` | `tpl-rocky10` | 10 |
| `901` | `pbs` — la VM Proxmox Backup Server, **hors pool** | 15 |
| `902` | `pulse` (CT) | 20 |

`pbs` n'est dans aucun pool : le job de sauvegarde `backup-lab` est « pool based », et
PBS ne doit pas se sauvegarder lui-même.

🪤 `app01` (Terraform, stack 02) et `cloud01` (manuel, 120) sont deux machines
distinctes. Le clone manuel ne s'appelle **pas** `app01` : Ansible indexe par nom, et
deux homonymes s'écraseraient dans l'inventaire.

*auto* : le provider Terraform ne fixe jamais de `vm_id`, Proxmox attribue le prochain
libre. On retrouve ces machines par leur **nom** (`qm list`, `terraform output`).

### Jour 4 : le cluster attribue

Un VMID est unique dans **tout** le cluster, et six stagiaires y créent des machines en
même temps :

```bash
VMID=$(pvesh get /cluster/nextid)        # CLI
```

L'interface web propose ce numéro d'elle-même ; Terraform fait de même (aucune stack ne fixe de `vm_id`).
Les machines du jour 4 portent le **nom de leur nœud** en suffixe (`evpn-prod-pve3`).

| Machine (jour 4) | VMID | TP |
|---|---|---|
| `evpn-prod-<nœud>`, `evpn-pub-<nœud>` | `nextid` | 17 |
| `ceph-vm-<nœud>` | `nextid` | 18 |
| `tpl-*` reconstruits sur chaque nœud | `nextid` | 16 |
| `front-<nœud>`, `app-<nœud>`, `data-<nœud>`, `cache-<nœud>`, `adm-<nœud>` | `nextid` (Terraform) | 21 |
| `pbs` sur **pve1** | `901` | 16 |
| `pulse` sur **pve1** | `902` | 20 |

🧠 **Pourquoi sur `pve1` ?** Il crée le cluster et porte l'exit node primaire : les
services de la salle y vont naturellement.

🪤 Deux `pvesh get /cluster/nextid` à la même seconde peuvent renvoyer le même
numéro : le second `qm create` échoue avec `VM already exists`. Relancez.

---

## 🏷️ Convention de tags

Les tags pilotent l'inventaire Ansible (TP 13).

### Tags de rôle (déclenchent un rôle Ansible)

| Tag | Rôle Ansible | Ce qu'il installe |
|---|---|---|
| `web` | `web` | nginx + vhost + page générée |
| `db` | `db` | PostgreSQL + `pg_hba` restreint |
| `monitoring` | `monitoring` | Prometheus / node exporter — rôle **à écrire**, bonus du TP 13 |

> Le rôle `nfs` ne passe pas par un tag : il s'applique à **votre poste Ubuntu**, via
> l'inventaire statique `lab/ansible/inventory/local.yml` (TP 14).

### Tags de zone

`interne` · `dmz` · `services` · `prod` · `pub`

### Tags d'OS

`debian` · `ubuntu` · `rocky` · `alpine` · `windows`

### Tags d'origine

`terraform` · `manuel`

### Exemples

```bash
qm set 120 --tags "manuel,debian,interne,app"     # cloud01
qm set $(qm list | awk '/ web01 /{print $1}') --tags "terraform,web,dmz,ubuntu"   # VMID Terraform : par le nom
pct set 111 --tags "manuel,web,dmz,alpine"
qm set 102 --tags "manuel,interne,windows"
qm set <vmid> --tags "manuel,ceph,prod"           # VM dont le disque est sur vm-store (jour 4)
```

### Couleurs (`Datacenter → Options → Tag Style Override`)

```
prod:CC2222:FFFFFF;dmz:EE7700:000000;interne:2277CC:FFFFFF;services:22AA55:FFFFFF;web:44AA22:FFFFFF;db:8844CC:FFFFFF;terraform:7B42BC:FFFFFF;windows:0078D4:FFFFFF;alpine:0D597F:FFFFFF;rocky:10B981:FFFFFF
```

---

## 👤 Comptes et rôles

| Compte | Realm | Rôle | Usage |
|---|---|---|---|
| `root@pam` | PAM | — | administration du nœud |
| `eleve@pve` | PVE | `PVEAdmin` | travail quotidien |
| `stagiaire@pve` | PVE | `PVEVMUser` sur `/pool/lab` (groupe `stagiaires`) | démonstration de délégation |
| `terraform@pve!tf` | token | `TerraformProv` | Terraform |
| `ansible@pve!inv` | token | `PVEAuditor` | inventaire Ansible |
| `pulse@pve!mon` | token | `Monitoring` | supervision (lecture seule) |
| `eleve@pbs` | PBS | `DatastoreAdmin` sur `/datastore/lab-store` (namespace `lab`) | sauvegardes |
| `client.admin` | Ceph | — | administration Ceph (clé dans `/etc/pve/priv/`) |
| `pulse@pbs!mon` | PBS | `Audit` | supervision PBS |

**Mot de passe unique du lab** : `Formation2026!`
🚨 C'est un lab. En production, un mot de passe par compte, dans un coffre.

---

## 💾 Stockages

**Pas de ZFS dans cette formation.** Les nœuds sont installés en `ext4 + LVM-thin`.

| ID | Type | Créé au | Portée | Contenu |
|---|---|---|---|---|
| `local` | `dir` | installation | nœud | iso, vztmpl, backup, snippets |
| **`local-lvm`** | `lvmthin` | installation | nœud | ⭐ **images, rootdir — le défaut** |
| `nfs-pc` | `nfs` | TP 14 | nœud | images, rootdir, iso, backup, snippets — export `/srv/nfs` du poste. En cluster : `nfs-<nœud>` avec `--nodes <nœud>` |
| `pbs-lab` | `pbs` | TP 15 | nœud (TP 15) · cluster (TP 16) | backup |
| **`vm-store`** | `rbd` (Ceph) | TP 18 | **cluster ×3 copies** | images, rootdir |
| `cephfs` | `cephfs` | TP 18 | **cluster ×3 copies** | iso, vztmpl, snippets, backup |

### Disposition LVM d'un nœud (exemple, disque de 480 Go)

```
   /dev/sda
   └── VG « pve »
       ├── root        60 Go   ext4, le système
       ├── swap         8 Go
       ├── data       200 Go   ⭐ pool LVM-thin  → stockage « local-lvm »
       ├── ceph-osd   120 Go   ⭐ volume dédié   → OSD Ceph (TP 18)
       └── libre       ~90 Go  marge LVM (garder 5-10 %)
```

🚨 **Deux métriques à surveiller** :

| Commande | Seuil critique |
|---|---|
| `lvs -o lv_name,data_percent` | **> 95 % sur `data` → les VM se corrompent** |
| `ceph df` / `ceph osd df` | **> 95 % → toutes les écritures du cluster s'arrêtent** |

🪤 **Un pool LVM-thin ne peut pas être réduit** (`lvreduce` refuse). D'où le réglage
`maxvz` à l'installation, qui laisse de l'espace libre pour `ceph-osd`.
Voir [TP 01 §3.1](../01-installation-proxmox.md) et [TP 18 §3](../18-ceph-cluster.md).

### Configuration Ceph du lab

| Élément | Valeur |
|---|---|
| Réseau public | `172.30.30.0/24` (⚠️ pas de réseau cluster dédié — limite du lab) |
| Monitors | `pve1`, `pve2`, `pve3` (3, impair) |
| Managers | `pve1` (actif), `pve2` (veille) |
| MDS (CephFS) | `pve1`, `pve2` |
| OSD | 1 par nœud, sur `/dev/pve/ceph-osd` → **6 OSD** |
| Pool `vm-store` | `size 3`, `min_size 2`, autoscale `on`, application `rbd` |
| CephFS | `cephfs`, `--add-storage 1` |
| Bridage recovery | `osd_max_backfills 1`, `osd_recovery_sleep 0.1` |

---

## ⏱️ Fenêtres planifiées

| Tâche | Horaire | Portée |
|---|---|---|
| Sauvegarde PBS | `02:30` quotidien | par pool `lab` |
| Prune PBS | `daily` | par namespace |
| Garbage collection PBS | `daily 05:00` | datastore |
| Verify PBS | `sat 03:00` | datastore |
| Sync hors site | `daily 04:00` | datastore |
| Ceph scrub / deep-scrub | automatique | par PG |

---

## 🧾 Fiche récapitulative

Quatre trous à remplir, le reste est commun.

```
   ┌────────────────────────────────────────────────────────┐
   │  MON POSTE                                             │
   ├────────────────────────────────────────────────────────┤
   │  Nœud        pve           $PVE = 172.30.30.___ :8006  │
   │              (jour 4 : pve__  — même IP)               │
   │  PC          $PC  = 172.30.30.___  (hostname -I)       │
   │  PBS         $PBS = 172.30.30.___  :8007  (TP 15/16)   │
   │  Pulse       $PULSE = 172.30.30.___ :7655 (TP 20)      │
   │  Pool        lab                                       │
   │                                                        │
   │  SDN jour 2  vint  10.10.10.0/24  gw 10.10.10.1        │
   │              vdmz  10.10.20.0/24  gw 10.10.20.1        │
   │              vsrv  10.10.30.0/24  gw 10.10.30.1        │
   │                                                        │
   │  SDN jour 4  vprod 10.60.10.0/24  (partagé)            │
   │              vpub  10.60.20.0/24  (partagé)            │
   │              vdb   10.60.30.0/24  (partagé, sans NAT)  │
   │                                                        │
   │  Machines    101 srv01    102 win01                    │
   │              111 alpine   112 rocky    120 cloud01     │
   │              190 tpl-debian13  191 tpl-ubuntu2604      │
   │              192 tpl-rocky10   901 pbs                 │
   │  Jour 4      VMID = pvesh get /cluster/nextid          │
   │                                                        │
   │  LVM         pve/data     200 Go  → local-lvm          │
   │              pve/ceph-osd 120 Go  → OSD Ceph           │
   │                                                        │
   │  Stockages   local-lvm   (défaut, local)               │
   │              nfs-pc      export /srv/nfs de mon poste  │
   │              pbs-lab     $PBS:8007                     │
   │              vm-store    Ceph, ×3 copies (J4)          │
   │              cephfs      Ceph, fichiers  (J4)          │
   └────────────────────────────────────────────────────────┘
```
