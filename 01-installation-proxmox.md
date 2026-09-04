# TP 01 — Installation de Proxmox VE 9 🏗️

⏱️ **1 h 30** · Jour 1

Objectif : passer d'une machine nue à un hyperviseur Proxmox VE 9 propre, à jour,
accessible en HTTPS et en SSH.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pve-installation.html>

---

## 1. Un peu de contexte avant de cliquer 🧠

Proxmox VE, ce n'est pas « un OS de virtualisation » mystérieux : c'est une **Debian**
(la 13 « Trixie » pour PVE 9) avec :

- un **noyau Ubuntu** (meilleur support matériel récent),
- **KVM/QEMU** pour les machines virtuelles complètes,
- **LXC** pour les conteneurs système,
- **`pve-cluster`** et son système de fichiers distribué **`pmxcfs`** monté sur `/etc/pve`,
- une **API REST** et une interface web en `:8006`.

```
   ┌──────────────────────────────────────────────────────┐
   │  Interface web (8006)   ·   API REST   ·   CLI (pve*)│
   ├──────────────────────────────────────────────────────┤
   │        pve-cluster  →  /etc/pve  (pmxcfs, corosync)  │
   ├───────────────────────┬──────────────────────────────┤
   │   QEMU/KVM (VM)       │       LXC (conteneurs)       │
   ├───────────────────────┴──────────────────────────────┤
   │   Debian 13  +  noyau Ubuntu  +  ZFS / LVM / Ceph    │
   └──────────────────────────────────────────────────────┘
```

🧠 **`/etc/pve` est magique** : ce n'est pas un vrai répertoire sur disque, c'est une
base SQLite exposée en système de fichiers et **répliquée sur tous les nœuds du
cluster**. Tout ce qu'on y écrit apparaît instantanément partout. C'est là que vivent
les configs de VM, le SDN, le firewall, les utilisateurs.

---

## 2. Préparer la clé USB

Sur votre PC Ubuntu :

```bash
# 1. Récupérer l'ISO (dernière 9.x)
#    https://www.proxmox.com/en/downloads
ls -lh ~/Téléchargements/proxmox-ve_9*.iso

# 2. Identifier la clé USB (ATTENTION à ne pas se tromper de disque)
lsblk -o NAME,SIZE,MODEL,TRAN | grep usb

# 3. Écrire l'image (remplacez sdX par VOTRE clé)
sudo dd if=~/Téléchargements/proxmox-ve_9.x-1.iso of=/dev/sdX \
        bs=4M status=progress oflag=direct conv=fsync
sync
```

🪤 `dd` ne demande **aucune confirmation**. Relisez la ligne deux fois.

---

## 3. Installation graphique

Bootez sur la clé, choisissez **Install Proxmox VE (Graphical)**.

### 3.1 Système de fichiers : **ext4 / LVM** 🎯

L'écran « Target Harddisk » → **Filesystem : `ext4`**.

C'est le choix de toute la formation, et il est délibéré :

| | Ce que ça donne |
|---|---|
| Simple | un VG `pve`, trois volumes : `root`, `swap`, `data` (le pool LVM-thin) |
| Léger en RAM | pas d'ARC à nourrir — tout est disponible pour vos VM |
| Snapshots | ✅ via LVM-thin |
| Manipulable | on va y faire de la chirurgie LVM au TP 18, pour Ceph |

🧠 **Et ZFS ?** ZFS est excellent (checksums de bout en bout, compression, réplication
`zfs send`), mais il réclame ~1 Go de RAM par To d'ARC, complique la manipulation du
disque, et ne nous apporte rien ici : le stockage partagé du jour 4 sera **Ceph**, pas
de la réplication ZFS. **On n'utilise pas ZFS dans cette formation.** Sachez qu'il
existe, et pourquoi on ne l'a pas retenu.

### 3.1 bis — ⚠️ L'option qui vous sauvera au TP 18 : `maxvz`

Bouton **Options**, toujours sur l'écran « Target Harddisk » :

| Champ | Valeur | Effet |
|---|---|---|
| `hdsize` | tout le disque | taille totale utilisée |
| `swapsize` | par défaut (≈ 8 Go) | |
| `maxroot` | par défaut (≈ 60 Go) | taille de `/` |
| **`maxvz`** | **⭐ hdsize − maxroot − swap − 80** | taille du pool LVM-thin `data` |

**Exemple, disque de 480 Go** : `maxroot 60`, `swap 8`, et `maxvz` = **330** au lieu de
la valeur par défaut (~410). On laisse ainsi **~80 Go d'espace non alloué** dans le
groupe de volumes.

🎯 **Pourquoi ?** Au TP 18, Ceph aura besoin d'un volume dédié. Or **un pool LVM-thin
ne peut pas être réduit** — c'est une limite de LVM, pas un réglage. Si le VG est plein,
la seule voie sera de détruire le pool, le recréer plus petit, et restaurer vos VM
depuis PBS. Cinq secondes de prévoyance ici vous économisent quarante minutes de
chirurgie au jour 4.

```
   AVEC maxvz réduit                  AVEC maxvz par défaut
   ─────────────────                  ─────────────────────
   VG pve                             VG pve
   ├── root    60 Go                  ├── root    60 Go
   ├── swap     8 Go                  ├── swap     8 Go
   ├── data   330 Go (thin)           └── data   410 Go (thin)
   └── LIBRE   80 Go  ← ⭐                        ↑
                                       0 octet libre → chirurgie au TP 18
```

> Si le formateur préfère faire vivre l'exercice de chirurgie LVM à tout le monde,
> laissez `maxvz` par défaut. Les deux chemins sont documentés au TP 18.

### 3.2 Localisation

| Champ | Valeur |
|---|---|
| Country | `France` (ou `New Caledonia`) |
| Time zone | celui de la salle |
| Keyboard | `French` |

### 3.3 Mot de passe et e-mail

Mot de passe root : **`Formation2026!`** (identique pour tous, c'est un lab).
E-mail : `eleve@formation.local` — il doit être syntaxiquement valide, pas réel.

### 3.4 Réseau — ⚠️ l'étape à ne pas rater

| Champ | Valeur |
|---|---|
| Management interface | votre carte Ethernet (`enp1s0`, `eno1`…) |
| Hostname (FQDN) | `pve.lab.local` ← **le FQDN est obligatoire** |
| IP address (CIDR) | **`$PVE/24`** — l'adresse que le formateur vous a attribuée (`.151` à `.156`) |
| Gateway | `172.30.30.2` |
| DNS server | `1.1.1.1` |

🧠 **Tout le monde s'appelle `pve`, et c'est voulu.** Pendant trois jours, chacun est
seul sur son nœud : le nom n'a pas besoin d'être unique, seule l'IP l'est. Ce nœud
sera **réinstallé au TP 16**, juste avant la mise en cluster, avec cette fois un
hostname distinct (`pve1` … `pve6`) — voilà pourquoi on ne s'embarrasse d'aucune
convention de numérotation d'ici là.

🪤 **Pièges classiques :**
- Un hostname sans domaine (`pve` au lieu de `pve.lab.local`) → refusé.
- Une IP en DHCP → au reboot elle change et l'interface web devient introuvable.
  Toujours en **statique** sur un hyperviseur.
- Se tromper de carte réseau (Wi-Fi, IPMI) → pas de réseau au reboot.

Validez, **Install**, patientez, retirez la clé au reboot.

---

## 4. Premier contact

### 4.1 Interface web 🌐

```
https://$PVE:8006
```

Le certificat est auto-signé → « Avancé » → « Continuer ».
Login : `root`, Realm : **Linux PAM standard authentication**.

Un bandeau apparaît : *« You do not have a valid subscription »*. C'est normal, on
n'a pas d'abonnement. On le traite au TP 02.

### 4.2 SSH 🖥️

Depuis votre PC :

```bash
PVE=172.30.30.___          # ⚠ l'IP de VOTRE nœud (TP 00 §2)
ssh-copy-id root@$PVE      # injecte votre clé publique
ssh root@$PVE
```

Vérifiez immédiatement :

```bash
pveversion -v | head -5
hostnamectl
ip -br a
ip route
cat /etc/network/interfaces
```

Vous devez voir un bridge `vmbr0` de ce genre (ici avec `.151` en exemple) :

```
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 172.30.30.151/24
        gateway 172.30.30.2
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0
```

🧠 **Comprendre `vmbr0`** : l'installateur a « déplacé » l'IP de la carte physique vers
un **bridge Linux**. La carte physique devient un simple port de ce switch virtuel.
L'hôte et les VM sont branchés sur le même switch, donc sur le même LAN.

```
                       ┌──────── vmbr0 (switch virtuel) ────────┐
                       │                                        │
   LAN ─── enp1s0 ─────┤  IP hôte $PVE/24                       │
                       │                                        │
                       │   ┌──────┐   ┌──────┐   ┌──────┐       │
                       └───┤ VM 1 ├───┤ VM 2 ├───┤ CT 1 ├───────┘
                           └──────┘   └──────┘   └──────┘
```

---

## 5. Configurer les dépôts (sans abonnement) 📦

Proxmox VE 9 utilise le format **deb822** (`.sources`), plus les anciens `.list`.

```bash
# Désactiver les dépôts « enterprise » (payants, renvoient 401)
mv /etc/apt/sources.list.d/pve-enterprise.sources \
   /etc/apt/sources.list.d/pve-enterprise.sources.disabled 2>/dev/null
mv /etc/apt/sources.list.d/ceph.sources \
   /etc/apt/sources.list.d/ceph.sources.disabled 2>/dev/null
```

```bash
# Activer le dépôt « no-subscription »
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
```

```bash
apt update && apt full-upgrade -y
```

> 💡 Tout ceci est faisable en clic-clic : `Datacenter → pve → Updates → Repositories`.
> On le fait en CLI pour comprendre ce qui se passe réellement.

### Retirer le bandeau d'abonnement (facultatif, lab uniquement)

```bash
sed -i.bak "s/data.status !== 'Active'/false/g" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy
```

⚠️ Ce patch est écrasé à chaque mise à jour de `proxmox-widget-toolkit`.
En production, **achetez un abonnement** : c'est ce qui finance le projet et vous donne
le dépôt `pve-enterprise`, testé et stable.

---

## 6. Hygiène de base 🧼

```bash
# Paquets utiles pour la suite de la formation
apt install -y vim tmux htop iftop tcpdump ethtool bridge-utils \
               frr frr-pythontools dnsmasq
```

🧠 On installe **`frr` + `frr-pythontools`** dès maintenant : ce sont les prérequis de
la zone EVPN du jour 4, et prendre l'habitude à froid évite un « pourquoi mon BGP ne
monte pas » à J+2 (la réinstallation du TP 16 reprendra exactement ces étapes). Et
**`dnsmasq`** pour le DHCP du SDN, qu'il faut désactiver en tant que service système :

```bash
systemctl disable --now dnsmasq
systemctl status dnsmasq --no-pager | head -3   # doit être inactive/disabled
```

🪤 Si `dnsmasq` tourne en service système, il occupe le port 53/67 et **les instances
`dnsmasq@<zone>` du SDN ne démarreront pas**.

### Heure : indispensable pour le cluster

```bash
timedatectl set-timezone Pacific/Noumea    # ou Europe/Paris
timedatectl status
chronyc sources -v 2>/dev/null || systemctl status systemd-timesyncd --no-pager | head -3
```

🧠 Corosync (le cluster du jour 4) est **très sensible** à la dérive d'horloge.
Un décalage de quelques secondes entre nœuds = des perturbations de quorum.

### Résolution de noms locale

Regardez ce que l'installateur a écrit dans `/etc/hosts` :

```
127.0.0.1       localhost.localdomain localhost
172.30.30.151   pve.lab.local pve      ← votre IP, votre hostname
```

🪤 **La ligne de votre propre nœud doit contenir votre vraie IP**, pas `127.0.1.1`.
Proxmox s'en sert pour savoir sur quelle adresse s'annoncer ; au jour 4, un nœud dont
le nom résout sur la loopback ne rejoint pas le cluster. Vérifiez dès maintenant :

```bash
hostname --ip-address     # doit renvoyer votre IP ($PVE), pas 127.x
```

> Les entrées des **six nœuds** de la salle viendront au TP 16, après la
> réinstallation — pour l'instant, vous êtes seul.

---

## 7. Un compte non-root pour l'interface web 👤

Bonne pratique : ne pas travailler en `root@pam` au quotidien.

```bash
pveum user add eleve@pve --password 'Formation2026!' --comment "Compte de TP"
pveum aclmod / --users eleve@pve --roles PVEAdmin
pveum user list
```

Reconnectez-vous en `eleve@pve` (realm **Proxmox VE authentication server**) pour
vérifier. Notez que ce compte ne peut pas ouvrir de shell root sur le nœud : c'est le
but.

---

## 8. Reboot de validation

```bash
reboot
```

Après le redémarrage :

```bash
ssh root@$PVE
pveversion
systemctl --failed
ip -br a
ping -c2 172.30.30.2
ping -c2 1.1.1.1
```

---

## ✅ Checklist de validation

- [ ] `pveversion` renvoie une version **9.x**
- [ ] L'interface web répond en `https://$PVE:8006`
- [ ] SSH par clé fonctionne (pas de mot de passe demandé)
- [ ] `apt update` ne renvoie **aucune** erreur 401
- [ ] `hostname --ip-address` renvoie l'IP de mon nœud, pas `127.x`
- [ ] `dpkg -l | grep frr-pythontools` renvoie une ligne
- [ ] `systemctl is-enabled dnsmasq` renvoie `disabled`
- [ ] `systemctl --failed` est vide
- [ ] Le fuseau horaire est correct

---

## 🎁 Bonus si vous avez de l'avance

1. **Fail2ban sur l'interface web** :
   `apt install fail2ban`, puis créer un jail sur `/var/log/daemon.log` filtrant
   `pvedaemon.*authentication failure`.
2. **Certificat Let's Encrypt** : `Datacenter → ACME`. Ne marchera pas sans DNS
   public — mais lisez l'écran, c'est instructif.
3. **Comparez `ip -d link show vmbr0`** avec la sortie de `brctl show` et repérez
   la table d'apprentissage MAC : `bridge fdb show br vmbr0`.

➡️ Suite : [TP 02 — Premiers pas et stockages](02-premiers-pas-stockage.md)
