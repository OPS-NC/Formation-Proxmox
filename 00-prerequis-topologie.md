# TP 00 — Prérequis, adressage et conventions 🧭

⏱️ **30 min** · Jour 1

Avant de toucher au premier serveur : on pose le plan. Cinq minutes de discipline ici
vous éviteront trois heures de « pourquoi mon IP est déjà prise ? » au jour 4.

---

## 1. Votre numéro d'élève

Le formateur vous attribue un numéro **N** entre **1** et **6**.
**Tout découle de ce numéro.** Notez-le quelque part.

```
   Élève N=3  →  nœud pve3
              →  IP de gestion 192.168.50.13
              →  VMID de 300 à 399
              →  subnets 10.3.10.0/24, 10.3.20.0/24, 10.3.30.0/24
              →  suffixe de nommage « -e3 »
```

---

## 2. Plan d'adressage physique

| Élément | Adresse | Note |
|---|---|---|
| Réseau de la salle | `192.168.50.0/24` | LAN plat, non modifiable |
| Passerelle / Internet | `192.168.50.254` | pas d'accès admin |
| DNS | `192.168.50.254` (ou `9.9.9.9`) | |
| Nœud Proxmox élève N | `192.168.50.1N` | pve1 = .11 … pve6 = .16 |
| PC Ubuntu élève N | `192.168.50.10N` | .101 … .106 |
| **Serveur NFS** | votre **PC Ubuntu** `192.168.50.10N` | jour 3, TP 14 |
| VM PBS (jour 3) | `192.168.50.41` | hébergée sur **pve1** |
| Pulse (jour 4) | `192.168.50.42` | LXC sur pve1 |

⚠️ **Rien d'autre ne doit prendre d'IP sur ce réseau.** Toutes vos VM de TP vivront
dans les réseaux SDN en `10.x.x.x`.

---

## 3. Plan de stockage 💾

Un seul principe : **on reste sur le stockage par défaut**, et on ajoute du partagé
progressivement.

| Stockage | Type | Créé au | Portée | Usage |
|---|---|---|---|---|
| `local` | `dir` | installation | nœud | ISO, templates LXC, snippets, dumps |
| **`local-lvm`** | `lvmthin` | installation | nœud | ⭐ **le stockage par défaut de tous les disques** |
| `nfs-eN` | `nfs` | TP 14 | nœud | export de **votre PC Ubuntu** : ISO, backups, snippets |
| `pbs-lab` | `pbs` | TP 15 | cluster | sauvegardes dédupliquées |
| `vm-store` | `rbd` (Ceph) | TP 18 | **cluster** | disques de VM répliqués ×3 |
| `cephfs` | `cephfs` | TP 18 | **cluster** | ISO et templates partagés |

🧠 **Pas de ZFS.** C'est un choix assumé : `ext4 + LVM-thin` est plus simple, plus léger
en RAM, et se manipule bien mieux quand il faudra libérer de la place pour Ceph. On
explique le pourquoi au [TP 01 §3.1](01-installation-proxmox.md).

```
   JOUR 1-2          JOUR 3                    JOUR 4
   ────────          ──────                    ──────
   local-lvm         + nfs-eN  (votre PC)      + vm-store  (Ceph, ×3 copies)
   (local, rapide)   + pbs-lab (sauvegardes)   + cephfs    (fichiers partagés)
       │                    │                        │
   pas de partage      partagé, mais            partagé ET redondé
                       un seul serveur          sans point de défaillance
```

---

## 4. Plan d'adressage SDN

### Machines du jour 1 (sur `vmbr0`)

| Machine | IP | OS | VMID |
|---|---|---|---|
| `srv01-eN` | `192.168.50.1N1` | Debian 13 (ISO netinstall) | `N01` |
| `ct-alpine-eN` | `192.168.50.1N2` | Alpine (LXC) | `N11` |
| `win01-eN` | `192.168.50.1N5` | Windows Server 2025 | `N02` |
| `ct-rocky-eN` | `192.168.50.1N6` | Rocky Linux (LXC) | `N12` |

À partir du TP 08, elles déménagent dans les réseaux SDN et repassent en DHCP.

### Jour 2 — nœud isolé (zones `Simple`, propres à chaque élève)

| VNet | Zone | Subnet | Gateway | Rôle |
|---|---|---|---|---|
| `vint` | `zint` | `10.N.10.0/24` | `10.N.10.1` | Réseau interne (back-office, base) |
| `vdmz` | `zdmz` | `10.N.20.0/24` | `10.N.20.1` | DMZ (services exposés) |
| `vsrv` | `zsrv` | `10.N.30.0/24` | `10.N.30.1` | 3ᵉ LAN, créé en Terraform (TP 12) |

### Jour 4 — cluster (zone `EVPN`, **partagée entre tous**)

| VNet | VNI | Subnet | Gateway | SNAT | Rôle |
|---|---|---|---|---|---|
| `vprod` | 11010 | `10.60.10.0/24` | `10.60.10.1` | ✅ | Production |
| `vpub` | 11020 | `10.60.20.0/24` | `10.60.20.1` | ✅ | DMZ publique |
| `vdb` | 11030 | `10.60.30.0/24` | `10.60.30.1` | ❌ | Bases de données, sans Internet |

Le VRF de la zone utilise le **VNI 10000**.

> Dans le cluster, l'IPAM distribue les IP automatiquement : deux élèves ne peuvent
> pas obtenir la même adresse. C'est tout l'intérêt.

---

## 5. Plan de VMID 🔢

**Règle absolue** : élève N ⇒ VMID de `N00` à `N99`.

| Élève | Plage | Exemples |
|---|---|---|
| 1 | 100 – 199 | 101 = première VM, 190 = template |
| 2 | 200 – 299 | |
| 3 | 300 – 399 | |
| 4 | 400 – 499 | |
| 5 | 500 – 599 | |
| 6 | 600 – 699 | |

Sous-découpage à l'intérieur de votre plage :

```
   N01         srv01-eN   Debian, installé par ISO          (TP 03)
   N02         win01-eN   Windows Server 2025               (TP 04)
   N11 – N19   conteneurs LXC                               (TP 05, 07)
   N20         app01-eN   clone cloud-init manuel           (TP 10)
   N21 – N49   VM déployées par Terraform                   (TP 11, 12)
   N60 – N69   VM dans les VNets EVPN                       (TP 16)
   N90 – N99   templates                                    (TP 10)
```

Et pour l'infrastructure commune, hébergée sur **pve1** : `901` = PBS, `902` = Pulse.
(Le serveur NFS, lui, n'est pas une VM : c'est votre PC Ubuntu.)

🧠 **Pourquoi c'est critique ?** Un VMID est **unique dans tout le cluster**. Au jour 4,
si deux élèves ont une VM 100, la mise en cluster échoue. On anticipe dès maintenant.

### 📌 La convention de notation dans les TP

Dans les **tableaux et le texte**, on écrit `N01`, `N90`, `pveN`, `10.N.10.0/24` :
le `N` est un **trou à remplir** par votre numéro.

Dans les **blocs de commandes**, c'est une vraie variable shell. Chaque bloc
commence donc par la définir, et les VMID s'écrivent `${N}01` :

```bash
N=3                       # ⚠ VOTRE numéro d'élève
qm set ${N}01 --tags "debian,interne"
pvesh create /cluster/sdn/vnets/vint/subnets --subnet 10.$N.10.0/24 ...
```

🪤 **`qm set N01` échoue** : `N01` n'est pas un nombre. Si vous copiez-collez un bloc
et que Proxmox répond `unable to parse VMID` ou `400 Parameter verification failed`,
c'est presque toujours un `${N}` oublié — ou un `N=` non défini dans le shell courant.

```bash
echo $N        # le réflexe avant de coller quoi que ce soit
```

---

## 6. Nommage

| Objet | Convention | Exemple (élève 3) |
|---|---|---|
| Nœud | `pveN` | `pve3` |
| VM | `<rôle><nn>-eN` | `srv01-e3`, `web01-e3` |
| Template | `tpl-<os>-eN` | `tpl-debian13-e3` |
| Conteneur | `ct-<rôle>-eN` | `ct-alpine-e3` |
| Pool de ressources | `eleveN` | `eleve3` |
| Tags | rôle + zone + OS + origine | `web,dmz,ubuntu,terraform,eleve3` |

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
ssh-keygen -t ed25519 -C "eleve$N@formation-proxmox" -f ~/.ssh/id_ed25519 -N ""
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
  pveN seul          pveN seul           pveN seul       cluster 6 nœuds
      │                  │                   │                 │
  installation      LXC Alpine          cloud-init        mise en cluster
  local-lvm         LXC Rocky           Terraform         EVPN / VXLAN
  VM Debian ISO     exploration UI      3e LAN en IaC     gw anycast
  VM Windows        vmbr1 natté         Ansible + tags    exit nodes
  console / RDP     SDN int + dmz       NFS (votre PC)    ★ CEPH ×3 copies
                    firewall            PBS               migration + HA
                                                          Pulse · challenge
```

---

## ✅ Checklist de validation

- [ ] Je connais mon numéro d'élève **N**
- [ ] Je sais quelles IP, quels VMID et quels subnets sont les miens
- [ ] `terraform version` (ou `tofu version`) répond sur mon PC
- [ ] `ansible --version` répond, et `community.proxmox` est installée
- [ ] `cat ~/.ssh/id_ed25519.pub` affiche ma clé
- [ ] Le dépôt est cloné dans `~/ProxmoxFormation`
- [ ] `lab/scripts/00-check-env.sh` ne signale aucune erreur
- [ ] La virtualisation matérielle est activée dans le BIOS du serveur
- [ ] J'ai noté qu'il faut réduire `maxvz` à l'installation (pour Ceph au TP 18)
- [ ] Je sais quels stockages seront créés, et quand

➡️ Suite : [TP 01 — Installation de Proxmox VE 9](01-installation-proxmox.md)
