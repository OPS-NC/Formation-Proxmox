# Annexe E — Plan d'adressage, VMID et tags 📇

La référence unique. En cas de doute, c'est ce document qui fait foi.

---

## 🌍 Réseau physique — LAN salle `192.168.50.0/24`

| Élément | Adresse | Note |
|---|---|---|
| Passerelle / Internet | `192.168.50.254` | box, aucun accès admin |
| DNS | `192.168.50.254` (secours : `9.9.9.9`) | |
| **Nœud pve1** | `192.168.50.11` | élève 1 · **exit node primaire** · héberge PBS et Pulse · crée le cluster · MON + MGR Ceph |
| **Nœud pve2** | `192.168.50.12` | élève 2 · exit node secondaire · MON + MGR Ceph |
| **Nœud pve3** | `192.168.50.13` | élève 3 · MON Ceph |
| **Nœud pve4** | `192.168.50.14` | élève 4 |
| **Nœud pve5** | `192.168.50.15` | élève 5 |
| **Nœud pve6** | `192.168.50.16` | élève 6 |
| PC élève 1 → 6 | `192.168.50.101` → `.106` | postes de pilotage |
| **Serveur NFS de chaque élève** | son **PC Ubuntu**, `192.168.50.10N` | TP 14 |
| **VM `pbs-lab`** | `192.168.50.41` | TP 15 · **hébergée sur pve1** · UI sur `:8007` |
| **CT `pulse`** | `192.168.50.42` | TP 20 · sur pve1 · UI sur `:7655` |
| Réservé | `192.168.50.50` → `.99` | extensions du formateur |

> 🧠 Le serveur NFS n'est **pas** une VM : c'est le PC Ubuntu de chaque élève, qui
> exporte `/srv/nfs-eN` vers son propre nœud (TP 14).

### Les VM du jour 1 (sur `vmbr0`, avant le passage au SDN)

| Machine | IP | Formule |
|---|---|---|
| `srv01-eN` (Debian ISO) | `192.168.50.1N1` | élève 3 → `.131` |
| `ct-alpine-eN` | `192.168.50.1N2` | élève 3 → `.132` |
| `win01-eN` (Windows) | `192.168.50.1N5` | élève 3 → `.135` |
| `ct-rocky-eN` | `192.168.50.1N6` | élève 3 → `.136` |

⚠️ À partir du TP 08, ces machines déménagent dans les VNets SDN et repassent en DHCP.

---

## 🕸️ Réseaux SDN — jour 2 (nœud isolé, zones `Simple`)

Chaque élève a **ses propres** subnets, préfixés par son numéro.

| VNet | Zone | Subnet | Gateway | DHCP | SNAT | Créé au |
|---|---|---|---|---|---|---|
| `vint` | `zint` | `10.N.10.0/24` | `10.N.10.1` | `.100`–`.200` | ✅ | TP 08 |
| `vdmz` | `zdmz` | `10.N.20.0/24` | `10.N.20.1` | `.100`–`.200` | ✅ | TP 08 |
| `vsrv` | `zsrv` | `10.N.30.0/24` | `10.N.30.1` | `.100`–`.200` | ✅ | TP 12 (Terraform) |
| *(temporaire)* `vmbr1` | — | `10.N.99.0/24` | `10.N.99.1` | `.100`–`.200` | ✅ | TP 07, supprimé ensuite |

**Exemple, élève 3** : `10.3.10.0/24`, `10.3.20.0/24`, `10.3.30.0/24`.

```
   Élève 1 → 10.1.x.x     Élève 4 → 10.4.x.x
   Élève 2 → 10.2.x.x     Élève 5 → 10.5.x.x
   Élève 3 → 10.3.x.x     Élève 6 → 10.6.x.x
```

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
| `2049` | TCP | NFS v4 (nœud → PC de l'élève) |
| `6789`, `3300` | TCP | Ceph monitors |
| `6800`–`7300` | TCP | Ceph OSD et MDS |
| `3128` | TCP | proxy SPICE |
| `5900`–`5999` | TCP | consoles VNC |
| `60000`–`60050` | TCP | migration de VM |

---

## 🔢 Plan de VMID

**Règle absolue : élève N ⇒ VMID de `N00` à `N99`.**

| Élève | Plage |
|---|---|
| 1 | `100` – `199` |
| 2 | `200` – `299` |
| 3 | `300` – `399` |
| 4 | `400` – `499` |
| 5 | `500` – `599` |
| 6 | `600` – `699` |
| **Commun** | `900` – `949` (infra partagée) |

### Sous-découpage à l'intérieur de votre plage

| Sous-plage | Contenu | TP |
|---|---|---|
| `N01` | `srv01-eN` — Debian, ISO | 03 |
| `N02` | `win01-eN` — Windows Server 2025 | 04 |
| `N11` | `ct-alpine-eN` | 05 |
| `N12` | `ct-rocky-eN` | 05 |
| `N14`–`N19` | conteneurs jetables | 05, 07 |
| `N20` | `app01-eN` — clone cloud-init manuel | 10 |
| `N21`–`N29` | déployés par Terraform | 11 |
| `N50`–`N59` | zone `vsrv` (Terraform) | 12 |
| `N60`–`N69` | VNets EVPN | 17 |
| `N70`–`N79` | VM sur Ceph (`vm-store`) | 18 |
| `N90` | `tpl-debian13-eN` | 10 |
| `N91` | `tpl-ubuntu2604-eN` | 10 |
| `N92` | `tpl-rocky10-eN` | 10 |

### VMID communs — tous sur **pve1**

| VMID | Machine | TP |
|---|---|---|
| `901` | `pbs-lab` | 15 |
| `902` | `pulse` (CT) | 20 |

🧠 **Pourquoi sur `pve1` ?** C'est le nœud qui *crée* le cluster au TP 16 : il conserve
ses guests, alors que les cinq autres doivent être vidés pour pouvoir le rejoindre.
Le serveur NFS, lui, n'est pas une VM — c'est le PC de chaque élève.

🧠 **Pourquoi c'est critique** : un VMID est unique dans **tout** le cluster. Deux
élèves avec une VM 100 ⇒ la mise en cluster du TP 16 échoue. Réglez `Next Free VMID
Range` dans `Datacenter → Options` (TP 06) pour que l'interface propose le bon numéro.

---

## 🏷️ Convention de tags

Les tags pilotent l'inventaire Ansible (TP 13). Ils ne sont **pas** décoratifs.

### Tags de rôle (déclenchent un rôle Ansible)

| Tag | Rôle Ansible | Ce qu'il installe |
|---|---|---|
| `web` | `web` | nginx + vhost + page générée |
| `db` | `db` | PostgreSQL + `pg_hba` restreint |
| `monitoring` | `monitoring` | Prometheus / node exporter (bonus) |

> Le rôle `nfs` ne passe pas par un tag : il s'applique à **votre poste Ubuntu**, via
> l'inventaire statique `lab/ansible/inventory/local.yml` (TP 14).

### Tags de zone

`interne` · `dmz` · `services` · `prod` · `pub`

### Tags d'OS

`debian` · `ubuntu` · `rocky` · `alpine` · `windows`

### Tags d'origine et de propriété

`terraform` · `manuel` · `eleve1` … `eleve6`

### Exemples

```bash
qm set 320 --tags "terraform,web,dmz,ubuntu,eleve3"
qm set 322 --tags "terraform,db,interne,rocky,eleve3"
pct set 311 --tags "manuel,web,dmz,alpine,eleve3"
qm set 302 --tags "manuel,interne,windows,eleve3"
qm set 370 --tags "manuel,ceph,prod,eleve3"      # VM dont le disque est sur vm-store
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
| `stagiaireN@pve` | PVE | `PVEVMUser` sur `/pool/eleveN` | démonstration de délégation |
| `terraform@pve!tf` | token | `TerraformProv` | Terraform |
| `ansible@pve!inv` | token | `PVEAuditor` | inventaire Ansible |
| `pulse@pve!mon` | token | `Monitoring` | supervision (lecture seule) |
| `eleveN@pbs` | PBS | `DatastoreAdmin` sur `/datastore/lab-store/eleveN` | sauvegardes |
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
| `nfs-eN` | `nfs` | TP 14 | nœud (`--nodes pveN`) | iso, backup, snippets, images |
| `pbs-lab` | `pbs` | TP 15 | cluster | backup |
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
| Réseau public | `192.168.50.0/24` (⚠️ pas de réseau cluster dédié — limite du lab) |
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
| Sauvegarde PBS | `02:30` quotidien | par pool `eleveN` |
| Prune PBS | `daily` | par namespace |
| Garbage collection PBS | `daily 05:00` | datastore |
| Verify PBS | `sat 03:00` | datastore |
| Sync hors site | `daily 04:00` | datastore |
| Ceph scrub / deep-scrub | automatique | par PG |

---

## 🧾 Fiche récapitulative — élève 3

À adapter à votre numéro. Imprimez-la, collez-la sur votre écran.

```
   ┌────────────────────────────────────────────────────────┐
   │  ÉLÈVE 3                                               │
   ├────────────────────────────────────────────────────────┤
   │  Nœud        pve3          192.168.50.13:8006          │
   │  PC          192.168.50.103                            │
   │  VMID        300 → 399                                 │
   │  Pool        eleve3                                    │
   │                                                        │
   │  SDN jour 2  vint  10.3.10.0/24   gw 10.3.10.1         │
   │              vdmz  10.3.20.0/24   gw 10.3.20.1         │
   │              vsrv  10.3.30.0/24   gw 10.3.30.1         │
   │                                                        │
   │  SDN jour 4  vprod 10.60.10.0/24  (partagé)            │
   │              vpub  10.60.20.0/24  (partagé)            │
   │              vdb   10.60.30.0/24  (partagé, sans NAT)  │
   │                                                        │
   │  Machines    301 srv01    302 win01                    │
   │              311 alpine   312 rocky                    │
   │              390 tpl-debian13  391 tpl-ubuntu          │
   │              392 tpl-rocky10                           │
   │                                                        │
   │  LVM         pve/data     200 Go  → local-lvm          │
   │              pve/ceph-osd 120 Go  → OSD Ceph           │
   │                                                        │
   │  Stockages   local-lvm   (défaut, local)               │
   │              nfs-e3      export de mon PC .103          │
   │              pbs-lab     192.168.50.41:8007             │
   │              vm-store    Ceph, ×3 copies (J4)           │
   │              cephfs      Ceph, fichiers  (J4)           │
   │                                                        │
   │  Services    Pulse  192.168.50.42:7655                 │
   └────────────────────────────────────────────────────────┘
```
