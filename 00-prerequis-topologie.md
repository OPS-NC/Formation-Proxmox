# TP 00 — Prérequis, adressage et conventions 🧭

⏱️ **30 min** · Jour 1

Avant de toucher au premier serveur : on pose le plan. Cinq minutes de discipline ici
vous éviteront trois heures de « pourquoi mon IP est déjà prise ? » au jour 4.

---

## 1. Votre nœud et votre poste

Le formateur vous attribue **un nœud Proxmox** — une machine physique de la salle, avec
son adresse IP dans `172.30.30.151` à `.156`. Vous y travaillez **seul** pendant trois
jours. Vous disposez aussi d'un **PC Ubuntu** : c'est votre poste de pilotage
(navigateur, `ssh`, `terraform`, `ansible`).

```
   Votre nœud   →  hostname pve  (pve.lab.local)
                →  IP de gestion : celle que le formateur vous donne  → $PVE
                →  https://$PVE:8006
   Votre poste  →  IP relevée sur la machine (hostname -I)            → $PC
```

🧠 **Pourquoi tout le monde a le même hostname, les mêmes VMID, les mêmes réseaux ?**
Parce qu'aux jours 1 à 3, chaque nœud est **isolé** : ce qui se passe sur le vôtre ne
concerne que vous. Et le jour 4 commence par une **réinstallation complète** de tous
les nœuds (TP 16), qui reçoivent alors les noms `pve1` … `pve6` avant d'être mis en
cluster. Aucune collision possible, donc **aucune adaptation à faire** dans les
commandes : le plan de ce document est le même pour tout le monde. Seules quatre
adresses varient, et ce sont des variables shell (§2).

---

## 2. Plan d'adressage physique

| Élément | Adresse | Note |
|---|---|---|
| Réseau de la salle | `172.30.30.0/24` | LAN plat, non modifiable |
| Passerelle / Internet | `172.30.30.2` | pas d'accès admin |
| DNS | `1.1.1.1` (primaire) et `8.8.8.8` (secours) | résolveurs publics |
| Nœuds Proxmox | `172.30.30.151` → `.156` | un par stagiaire, **attribué par le formateur** → `$PVE` |
| VM du jour 1 sur `vmbr0` | **DHCP de la salle** | on relève l'IP obtenue, voir §4 |
| Adresses statiques sur `vmbr0` | `172.30.30.200` → `.250` | **attribuées par le formateur** : VM PBS, CT Pulse, ou une VM du jour 1 si la salle n'a pas de DHCP |
| PC Ubuntu | **`$PC`** | ⚠️ à relever sur le poste, voir ci-dessous |
| **Serveur NFS** | votre **PC Ubuntu**, donc `$PC` | jour 3, TP 14 |
| VM PBS | **`$PBS`** | jour 3 : la vôtre, sur votre nœud (TP 15) · jour 4 : celle de la salle, sur `pve1` (TP 16) |
| Pulse | **`$PULSE`** | LXC sur `pve1`, jour 4 — adresse fixée au TP 20 |

⚠️ **Seule la plage `.151`–`.156` des nœuds est figée.** Les autres adresses vous sont
**communiquées par le formateur** ou se relèvent sur la machine — ne les inventez pas,
et ne recopiez pas celles d'un voisin.

| Variable | Ce que c'est | Comment l'obtenir |
|---|---|---|
| `$PVE` | votre nœud Proxmox | donnée par le formateur |
| `$PC` | votre poste Ubuntu | sur le PC : `hostname -I \| awk '{print $1}'` |
| `$PBS` | la VM Proxmox Backup Server | fixée au TP 15 (puis au TP 16 pour la salle) |
| `$PULSE` | le conteneur Pulse | fixé au TP 20, commun à la salle |

📌 **Notez ces valeurs dès maintenant**, vous les retaperez souvent :

```bash
# À garder sous la main — à recopier au début de chaque session de travail
export PVE=172.30.30.___       # votre nœud Proxmox  (donné par le formateur)
export PC=172.30.30.___        # votre poste Ubuntu   (hostname -I sur le PC)
export PBS=172.30.30.___       # renseigné au TP 15
export PULSE=172.30.30.___     # renseigné au TP 20
```

⚠️ **En dehors de ces cas, rien d'autre ne doit prendre d'IP sur ce réseau.** Toutes vos
VM de TP vivront dans les réseaux SDN en `10.x.x.x` à partir du TP 08.

---

## 3. Plan de stockage 💾

Un seul principe : **on reste sur le stockage par défaut**, et on ajoute du partagé
progressivement.

| Stockage | Type | Créé au | Portée | Usage |
|---|---|---|---|---|
| `local` | `dir` | installation | nœud | ISO, templates LXC, snippets, dumps |
| **`local-lvm`** | `lvmthin` | installation | nœud | ⭐ **le stockage par défaut de tous les disques** |
| `nfs-pc` | `nfs` | TP 14 | nœud | export de **votre PC Ubuntu** : images, rootdir, ISO, backups, snippets |
| `pbs-lab` | `pbs` | TP 15 | nœud (TP 15) · cluster (TP 16) | sauvegardes dédupliquées |
| `vm-store` | `rbd` (Ceph) | TP 18 | **cluster** | disques de VM répliqués ×3 |
| `cephfs` | `cephfs` | TP 18 | **cluster** | ISO et templates partagés |

🧠 **Pas de ZFS.** C'est un choix assumé : `ext4 + LVM-thin` est plus simple, plus léger
en RAM, et se manipule bien mieux quand il faudra libérer de la place pour Ceph. On
explique le pourquoi au [TP 01 §3.1](01-installation-proxmox.md).

```
   JOUR 1-2          JOUR 3                    JOUR 4
   ────────          ──────                    ──────
   local-lvm         + nfs-pc  (votre PC)      + vm-store  (Ceph, ×3 copies)
   (local, rapide)   + pbs-lab (sauvegardes)   + cephfs    (fichiers partagés)
       │                    │                        │
   pas de partage      partagé, mais            partagé ET redondé
                       un seul serveur          sans point de défaillance
```

---

## 4. Plan d'adressage SDN

### Machines du jour 1 (sur `vmbr0`)

Elles sont branchées directement sur le LAN de la salle et prennent leur adresse en
**DHCP**. On ne fixe rien : on **relève** l'IP obtenue.

| Machine | OS | VMID | Adresse | Où la lire |
|---|---|---|---|---|
| `srv01` | Debian 13 (ISO netinstall) | `101` | DHCP | Summary de la VM (agent QEMU), ou `ip -br a` dans la console |
| `win01` | Windows Server 2025 | `102` | DHCP | Summary de la VM (agent), ou `ipconfig` |
| `ct-alpine` | Alpine (LXC) | `111` | DHCP | `pct exec 111 -- ip -4 -br a show eth0` |
| `ct-rocky` | Rocky Linux (LXC) | `112` | DHCP | `pct exec 112 -- ip -4 -br a show eth0` |

```bash
# Sur le nœud : l'IP d'une VM (agent QEMU requis) et d'un conteneur
qm agent 101 network-get-interfaces | jq -r '.[] | select(.name!="lo") | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | ."ip-address"'
pct exec 111 -- ip -4 -br a show eth0
```

> Si la salle n'a pas de DHCP, le formateur vous attribue des adresses statiques dans
> `172.30.30.200`–`.250`. Dans les TP, les adresses de ces machines sont notées
> `<IP-de-srv01>`, `<IP-de-ct-alpine>`… : remplacez par ce que vous avez relevé.

À partir du TP 08, ces machines déménagent dans les réseaux SDN.

### Jour 2 — nœud isolé (zones `Simple`, identiques pour tous)

Ces réseaux vivent **derrière le NAT de votre nœud** : six stagiaires avec les mêmes
`10.10.x.0/24` ne se gênent pas, exactement comme six box Internet en `192.168.1.0/24`.

| VNet | Zone | Subnet | Gateway | Rôle |
|---|---|---|---|---|
| `vint` | `zint` | `10.10.10.0/24` | `10.10.10.1` | Réseau interne (back-office, base) |
| `vdmz` | `zdmz` | `10.10.20.0/24` | `10.10.20.1` | DMZ (services exposés) |
| `vsrv` | `zsrv` | `10.10.30.0/24` | `10.10.30.1` | 3ᵉ LAN, créé en Terraform (TP 12) |
| *(temporaire)* `vmbr1` | — | `10.10.99.0/24` | `10.10.99.1` | TP 07, supprimé ensuite |

Depuis votre PC, tous ces réseaux se joignent **directement** grâce à une route posée
au TP 07 : `sudo ip route add 10.10.0.0/16 via $PVE`. Jamais de rebond SSH par le nœud.

### Jour 4 — cluster (zone `EVPN`, **partagée entre tous**)

| VNet | VNI | Subnet | Gateway | SNAT | Rôle |
|---|---|---|---|---|---|
| `vprod` | 11010 | `10.60.10.0/24` | `10.60.10.1` | ✅ | Production |
| `vpub` | 11020 | `10.60.20.0/24` | `10.60.20.1` | ✅ | DMZ publique |
| `vdb` | 11030 | `10.60.30.0/24` | `10.60.30.1` | ❌ | Bases de données, sans Internet |

Le VRF de la zone utilise le **VNI 10000**. Depuis le PC : `sudo ip route add
10.60.0.0/16 via 172.30.30.151` (l'exit node primaire, TP 17).

> Dans le cluster, l'IPAM distribue les IP automatiquement : deux stagiaires ne peuvent
> pas obtenir la même adresse. C'est tout l'intérêt.

---

## 5. Plan de VMID 🔢

**Jours 1 à 3 : les VMID sont fixés**, et les mêmes pour tout le monde — vous êtes seul
sur votre nœud.

| VMID | Machine | TP |
|---|---|---|
| `101` | `srv01` — Debian, installé par ISO | 03 |
| `102` | `win01` — Windows Server 2025 | 04 |
| `103` | VM jetable (clone de test de `srv01`, détruit aussitôt) | 03 |
| `111` | `ct-alpine` | 05 |
| `112` | `ct-rocky` | 05 |
| `113`–`115` | conteneurs jetables (restauration, template, clone) | 05 |
| `119` | `ct-nat` — conteneur de test sur `vmbr1` | 07 |
| `120` | `cloud01` — clone cloud-init **manuel** (IP fixe `10.10.10.50`) | 10 |
| *auto* | tout ce que crée **Terraform** (`web01`, `app01`, `db01`, `ct-cache`, `mon01`, `log01`) | 11, 12 |
| `180`–`189` | bonus : dix Alpine d'un coup | 05 |
| `190` / `191` / `192` | `tpl-debian13` / `tpl-ubuntu2604` / `tpl-rocky10` | 10 |
| `901` | `pbs` — la VM Proxmox Backup Server (**hors pool** : sinon elle se sauvegarderait elle-même) | 15 |
| `902` | `pulse` — le conteneur Pulse | 20 |

🧠 **Deux machines s'appellent `app01`, ce n'est pas une erreur du plan… et c'est pour
ça que le clone manuel s'appelle `cloud01`.** `app01` est la VM Debian déployée par
Terraform (stack 02) ; `cloud01` (120) est celle que vous clonez à la main au TP 10.
Ansible indexe les machines par leur nom : deux homonymes, et l'un écrase l'autre.

🧠 **Les machines Terraform n'ont pas de VMID dans ce plan**, et c'est voulu : le
provider demande à Proxmox le prochain numéro libre. On retrouve une machine par son
**nom** (`qm list`) ou dans `terraform output`, jamais par un numéro appris par cœur.

**Jour 4 : le cluster choisit.** Six stagiaires créent des machines dans le même
cluster, et un VMID est **unique dans tout le cluster**. On ne calcule rien : on laisse
Proxmox attribuer le prochain numéro libre.

```bash
TPL=$(qm list | awk '/tpl-debian13/{print $1}')   # les templates aussi ont un VMID « auto » au jour 4
VMID=$(pvesh get /cluster/nextid)                  # en CLI
qm clone $TPL $VMID --name evpn-prod-$(hostname) --full 1
```

L'interface web propose d'elle-même ce numéro, et Terraform fait pareil : **aucune
stack ne fixe de `vm_id`**, dès le jour 3. Les VM du jour 4 portent le **nom de leur nœud** en suffixe
(`evpn-prod-pve3`) : c'est ce qui permet de s'y retrouver dans la vue globale.

🪤 Deux stagiaires qui lancent `pvesh get /cluster/nextid` à la même seconde peuvent
obtenir le même numéro : le second `qm create` échoue avec `VM already exists`. On
relance, c'est tout.

### 📌 La convention de notation dans les TP

Les commandes se copient-collent **telles quelles** : aucun numéro à adapter. Quatre
valeurs seulement varient d'un poste à l'autre, et ce sont de **vraies variables shell**
(§2) : **`$PVE`**, **`$PC`**, **`$PBS`** et **`$PULSE`**. Chaque bloc qui en utilise une
la rappelle en tête :

```bash
PVE=172.30.30.___        # ⚠ l'IP de VOTRE nœud
ssh root@$PVE
```

Les adresses relevées sur une machine (une VM en DHCP, une IP attribuée par l'IPAM)
s'écrivent `<IP-de-srv01>`, `<ip-web01>`… : remplacez par ce que vous avez lu.

```bash
echo $PVE $PC        # le réflexe avant de coller un bloc côté PC
```

---

## 6. Nommage

| Objet | Convention | Exemple |
|---|---|---|
| Nœud | `pve` (jours 1-3) · `pve1` … `pve6` (jour 4) | `pve`, `pve3` |
| VM | `<rôle><nn>` | `srv01`, `web01`, `db01` |
| Template | `tpl-<os>` | `tpl-debian13` |
| Conteneur | `ct-<rôle>` | `ct-alpine` |
| VM du jour 4 (cluster partagé) | `<rôle>-<nœud>` | `evpn-prod-pve3` |
| Pool de ressources | `lab` | `lab` |
| Tags | rôle + zone + OS + origine | `web,dmz,ubuntu,terraform` |

🧠 **Les tags ne sont pas décoratifs** : au TP 13, Ansible construit son inventaire à
partir d'eux. Un tag `web` posé ici déclenche le rôle `web` là-bas. Le détail est dans
[`annexes/E-plan-adressage.md`](annexes/E-plan-adressage.md).

---

## 7. Préparer le PC Ubuntu 26.04 💻

```bash
sudo apt update
sudo apt install -y git curl jq dnsutils sshpass net-tools \
                    ca-certificates gnupg software-properties-common \
                    ansible python3-proxmoxer python3-requests \
                    freerdp3-x11 virt-viewer
ansible-galaxy collection install community.general ansible.posix \
                                 community.proxmox community.postgresql
```

> ⚠️ **`community.proxmox` n'est pas optionnelle.** Le plugin d'inventaire
> `community.general.proxmox` est déprécié : il n'est plus qu'une redirection
> vers `community.proxmox.proxmox` (suppression annoncée en `community.general`
> 15.0.0), et la redirection exige que la collection cible soit installée.
> Sans elle, l'inventaire du TP 13 sort vide.

> `freerdp3-x11` et `virt-viewer` servent au TP 04 (Windows en RDP et SPICE).
> Selon la version d'Ubuntu, le paquet peut s'appeler `freerdp2-x11`.

### Terraform (ou OpenTofu, au choix)

```bash
# Terraform (HashiCorp)
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
terraform version
```

```bash
# OU OpenTofu (fork libre, 100 % compatible avec les TP)
sudo snap install --classic opentofu
tofu version
```

> Dans tous les TP, remplacez `terraform` par `tofu` si vous avez choisi OpenTofu.

### Cloner le dépôt de la formation

```bash
git clone <url-du-depot> ~/ProxmoxFormation
cd ~/ProxmoxFormation
bash lab/scripts/00-check-env.sh
```

### Générer une clé SSH (si vous n'en avez pas)

```bash
ssh-keygen -t ed25519 -C "eleve@formation-proxmox" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

📌 **Gardez cette clé publique sous la main** : elle sera injectée dans toutes vos VM
par cloud-init.

---

## 8. Matériel du nœud Proxmox

Vérifiez avant l'installation :

| Point | Attendu | Comment vérifier |
|---|---|---|
| CPU 64 bits | oui | `lscpu` |
| Virtualisation matérielle | VT-x / AMD-V **activée dans le BIOS** | `grep -Ec '(vmx\|svm)' /proc/cpuinfo` ≥ 1 |
| RAM | 16 Go minimum, 32 Go confortable | |
| Disque | 1 disque système (**≥ 240 Go**, 480 Go confortable) | `lsblk` |
| 2ᵉ disque | facultatif — 🎁 idéal pour Ceph au TP 18 | `lsblk` |
| Réseau | 1 NIC Ethernet filaire | |
| Boot | UEFI de préférence | |

🪤 Sans VT-x/AMD-V, Proxmox s'installe mais **aucune VM KVM ne démarrera**.
Si le compteur ci-dessus renvoie 0, direction le BIOS.

### 🎯 Le réglage à ne pas rater à l'installation

Le disque sera partitionné en **ext4 / LVM** (pas de ZFS dans cette formation).
Il faudra **réduire `maxvz`** pour laisser ~80 Go non alloués dans le groupe de volumes :
Ceph en aura besoin au TP 18, et **un pool LVM-thin ne peut pas être réduit après
coup**. Les détails sont dans [TP 01 §3.1](01-installation-proxmox.md) — ne sautez pas
cette page.

---

## 9. Ce que vous allez construire en 4 jours

```
   JOUR 1              JOUR 2              JOUR 3            JOUR 4
 ────────────      ──────────────      ─────────────    ───────────────
  pve seul           pve seul            pve seul        cluster 6 nœuds
      │                  │                   │                 │
  installation      LXC Alpine          cloud-init        réinstallation
  local-lvm         LXC Rocky           Terraform         cluster · EVPN
  VM Debian ISO     exploration UI      3e LAN en IaC     gw anycast
  VM Windows        vmbr1 natté         Ansible + tags    exit nodes
  console / RDP     SDN int + dmz       NFS (votre PC)    ★ CEPH ×3 copies
                    firewall            PBS               migration + HA
                                                          Pulse · challenge
```

---

## ✅ Checklist de validation

- [ ] Je connais l'IP de mon nœud (`$PVE`) et je l'ai notée
- [ ] J'ai relevé l'IP de mon poste Ubuntu (`hostname -I`, `$PC`) et je l'ai notée
- [ ] Je sais que VMID, réseaux SDN et noms sont les mêmes pour tous aux jours 1-3, et pourquoi
- [ ] `terraform version` (ou `tofu version`) répond sur mon PC
- [ ] `ansible --version` répond, et `community.proxmox` est installée
- [ ] `cat ~/.ssh/id_ed25519.pub` affiche ma clé
- [ ] Le dépôt est cloné dans `~/ProxmoxFormation`
- [ ] `lab/scripts/00-check-env.sh` ne signale aucune erreur
- [ ] La virtualisation matérielle est activée dans le BIOS du serveur
- [ ] J'ai noté qu'il faut réduire `maxvz` à l'installation (pour Ceph au TP 18)
- [ ] Je sais quels stockages seront créés, et quand

➡️ Suite : [TP 01 — Installation de Proxmox VE 9](01-installation-proxmox.md)
