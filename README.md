# Formation Proxmox VE 9 — 4 jours 🧱

Formation pratique et intensive sur **Proxmox VE 9.x** (base Debian 13 « Trixie »).
Objectif : partir d'une machine nue et arriver à un **cluster de 6 nœuds**, avec du
**SDN EVPN/VXLAN**, un **firewall segmenté**, du **stockage partagé**, de la
**sauvegarde PBS**, et tout ça piloté en **Terraform + Ansible**.

> Format : 90 % de manipulations, 10 % de théorie. Chaque TP est autonome, testable,
> et se termine par une checklist de validation.

---

## 🎯 Ce que vous saurez faire à la fin

| # | Compétence |
|---|---|
| 1 | Installer et sécuriser un nœud Proxmox VE 9 |
| 2 | Créer des VM Linux **et Windows** depuis un ISO, et des conteneurs LXC |
| 3 | Naviguer dans toute l'interface : pools, tags, permissions, tokens, tâches |
| 4 | Concevoir un réseau segmenté avec le SDN (zones, VNets, subnets, IPAM, DHCP) |
| 5 | Écrire des règles de firewall inter-zones en *default deny* |
| 6 | Fabriquer des templates cloud-init en CLI et les cloner |
| 7 | Déployer un parc multi-OS avec Terraform, réseau et firewall compris |
| 8 | Piloter ce parc avec Ansible et un **inventaire dynamique par tags Proxmox** |
| 9 | Monter un cluster de 6 nœuds et comprendre le quorum |
| 10 | Étendre le SDN sur tout le cluster en **EVPN/VXLAN** avec sortie Internet |
| 11 | Brancher du stockage partagé NFS, migrer à chaud, faire de la HA |
| 12 | Installer Proxmox Backup Server, sauvegarder, restaurer, superviser |

---

## 🗺️ Topologie de la salle

```
                              ☁  Internet
                                   │
                        ┌──────────┴──────────┐
                        │   Routeur / Box     │  192.168.50.254
                        │  (aucun accès admin)│  ← contrainte du lab
                        └──────────┬──────────┘
                                   │
  ═══════════════════════ LAN SALLE  192.168.50.0/24 ═══════════════════════
        │           │           │           │           │           │
   ┌────┴───┐  ┌────┴───┐  ┌────┴───┐  ┌────┴───┐  ┌────┴───┐  ┌────┴───┐
   │  pve1  │  │  pve2  │  │  pve3  │  │  pve4  │  │  pve5  │  │  pve6  │
   │  .11   │  │  .12   │  │  .13   │  │  .14   │  │  .15   │  │  .16   │
   └────────┘  └────────┘  └────────┘  └────────┘  └────────┘  └────────┘
     élève 1     élève 2     élève 3     élève 4     élève 5     élève 6

   ┌──────────┐  Chaque élève dispose aussi d'un PC Ubuntu 26.04
   │ PC Ubuntu│  (192.168.50.101 → .106) : navigateur, ssh, git,
   │  élève N │  terraform, ansible. C'est votre poste de pilotage.
   └──────────┘
```

**Contrainte structurante du lab** : les nœuds sont tous sur **un seul LAN plat**, et
vous n'avez **aucun accès au switch ni au routeur**. Impossible de créer des VLAN en
amont, impossible de faire du BGP avec le routeur. C'est précisément ce cas de figure —
très courant en hébergement mutualisé, chez un provider, ou en agence — qui va nous
imposer le choix **EVPN + exit nodes + SNAT** au jour 4.
👉 Le raisonnement complet est dans [`SDN.md`](SDN.md).

---

## 📅 Programme

### Jour 1 — Fondations et premières machines 🏗️
| TP | Fichier | Durée |
|---|---|---|
| 00 | [Prérequis, adressage et conventions](00-prerequis-topologie.md) | 30 min |
| 01 | [Installation de Proxmox VE 9](01-installation-proxmox.md) | 1 h 30 |
| 02 | [Premiers pas, dépôts, stockages](02-premiers-pas-stockage.md) | 1 h 30 |
| 03 | [VM Debian 13 via ISO netinstall](03-vm-iso-debian.md) | 1 h 30 |
| 04 | [VM Windows Server 2025 via ISO, console et RDP](04-vm-windows-server.md) | 1 h 30 |

### Jour 2 — Conteneurs, interface, réseau et sécurité 🌐
| TP | Fichier | Durée |
|---|---|---|
| 05 | [Conteneurs LXC : Alpine et Rocky Linux](05-lxc-alpine-rocky.md) | 1 h 15 |
| 06 | [Exploration complète de l'interface Proxmox](06-exploration-interface.md) | 1 h 15 |
| 07 | [Réseau « à l'ancienne » : vmbr1 natté](07-reseau-classique-vmbr1-nat.md) | 45 min |
| 08 | [SDN : les 2 LAN `internal` et `dmz`](08-sdn-simple-internal-dmz.md) | 2 h |
| 09 | [Firewall inter-zones en *default deny*](09-firewall-inter-zones.md) | 1 h 45 |

### Jour 3 — Industrialisation : cloud-init, Terraform, Ansible 🤖
| TP | Fichier | Durée |
|---|---|---|
| 10 | [Cloud-image en CLI, cloud-init et clonage](10-cloudinit-cli-clonage.md) | 1 h 30 |
| 11 | [Terraform : déployer dans les réseaux SDN](11-terraform-vms-sdn.md) | 1 h 45 |
| 12 | [Terraform : un 3ᵉ LAN + ses règles de firewall](12-terraform-sdn-troisieme-lan.md) | 1 h 15 |
| 13 | [Ansible : inventaire dynamique Proxmox et rôles par tags](13-ansible-inventory-proxmox.md) | 1 h 45 |
| 14 | [Serveur NFS déployé en Terraform + Ansible](14-nfs-terraform-ansible.md) | 1 h |

### Jour 4 — Cluster, SDN distribué, sauvegarde et exploitation 🚀
| TP | Fichier | Durée |
|---|---|---|
| 15 | [Mise en cluster des 6 nœuds](15-cluster-proxmox.md) | 1 h 15 |
| 16 | [SDN en cluster : EVPN/VXLAN et limites du LAN plat](16-sdn-evpn-cluster.md) | 2 h 15 |
| 17 | [Stockage partagé, migration à chaud et HA](17-migration-ha.md) | 1 h |
| 18 | [Proxmox Backup Server](18-proxmox-backup-server.md) | 1 h 30 |
| 19 | [Pulse : une autre UI de supervision](19-pulse-monitoring.md) | 30 min |
| 20 | [Challenge final 🏁](20-challenge-final.md) | 45 min |

---

## 📚 Documents transverses

| Document | Contenu |
|---|---|
| [`SDN.md`](SDN.md) | **Référence complète** du SDN Proxmox VE 9 : toutes les fonctionnalités, ce qu'elles apportent, quand les utiliser, et le choix de topologie pour ce lab |
| [`annexes/A-cheatsheet-cli.md`](annexes/A-cheatsheet-cli.md) | Toutes les commandes utiles, classées |
| [`annexes/B-troubleshooting.md`](annexes/B-troubleshooting.md) | Les pannes classiques et leur résolution |
| [`annexes/C-glossaire.md`](annexes/C-glossaire.md) | VTEP, VNI, VRF, quorum, EVPN… en français |
| [`annexes/D-references.md`](annexes/D-references.md) | Liens vers la doc officielle, par chapitre |
| [`annexes/E-plan-adressage.md`](annexes/E-plan-adressage.md) | Le plan d'adressage, de VMID et de tags complet |

---

## 📦 Contenu du dépôt

```
ProxmoxFormation/
├── README.md                 ← vous êtes ici
├── SDN.md                    ← la bible SDN
├── 00..20-*.md               ← les TP, dans l'ordre
├── annexes/                  ← cheatsheets, glossaire, dépannage
└── lab/
    ├── scripts/              ← scripts prêts à l'emploi (bash)
    ├── cloud-init/           ← fichiers user-data / vendor-data
    ├── sdn/                  ← configurations SDN de référence
    │   ├── standalone/       ← jour 2 (nœud seul)
    │   └── cluster-evpn/     ← jour 4 (cluster)
    ├── firewall/             ← fichiers .fw d'exemple
    ├── terraform/            ← 4 stacks Terraform progressives
    └── ansible/              ← inventaire dynamique + rôles
```

---

## 🚀 Démarrage

Sur votre **PC Ubuntu 26.04** :

```bash
git clone <url-du-depot> ~/ProxmoxFormation
cd ~/ProxmoxFormation
bash lab/scripts/00-check-env.sh
```

Le script vérifie que `ssh`, `git`, `terraform`/`tofu`, `ansible`, `jq`, `curl` et
`dig` sont présents, et vous indique quoi installer sinon.

Puis ouvrez [`00-prerequis-topologie.md`](00-prerequis-topologie.md).

---

## ⚠️ Conventions de lecture

| Symbole | Signification |
|---|---|
| 💻 | Commande à taper sur **votre PC Ubuntu** |
| 🖥️ | Commande à taper sur **le nœud Proxmox** (shell / SSH) |
| 🌐 | Action à faire dans **l'interface web** `https://192.168.50.1N:8006` |
| ✅ | Point de validation : ça doit marcher avant de continuer |
| 🧠 | Explication de fond, à lire (ce n'est pas du remplissage) |
| 🪤 | Piège classique |
| 🎁 | Bonus si vous avez de l'avance |

Dans tous les fichiers, `N` = **votre numéro d'élève** (1 à 6).
Si vous êtes l'élève 3 : `pve3`, `192.168.50.13`, VMID `300-399`, subnets `10.3.x.0/24`.

---

## 🧾 Versions de référence

| Composant | Version visée | Vérification |
|---|---|---|
| Proxmox VE | 9.x (Debian 13) | `pveversion -v` |
| Proxmox Backup Server | 4.x | `proxmox-backup-manager version` |
| Debian (VM) | 13 « Trixie » | ISO netinstall + cloud image |
| Windows Server | 2025 (évaluation 180 j) | ISO Microsoft Evaluation Center |
| Ubuntu (VM) | 26.04 LTS | cloud image server |
| Rocky Linux | 10 | GenericCloud (VM) + template LXC |
| Alpine (LXC) | 3.2x | template `pveam` |
| Terraform / OpenTofu | ≥ 1.9 | `terraform version` |
| Provider Proxmox | `bpg/proxmox` ≥ 0.80 | `terraform providers` |
| Ansible | ≥ 2.17 (`community.general`) | `ansible --version` |

> 📖 Toute la formation s'appuie sur la documentation officielle :
> <https://pve.proxmox.com/pve-docs/>. Chaque TP renvoie au chapitre concerné.
