# TP 10 — Cloud-image en CLI, cloud-init et clonage ☁️

⏱️ **1 h 15** · Jour 3

Objectif : fabriquer, entièrement en ligne de commande, des templates de VM à partir de
cloud-images, prêts à être clonés en 15 secondes. C'est la fondation de tout le jour 3.

📖 Doc : <https://pve.proxmox.com/pve-docs/qm.html#qm_cloud_init>
📖 cloud-init : <https://cloudinit.readthedocs.io/>

---

## 1. Pourquoi cloud-init change tout 🧠

Au TP 03, installer une VM a pris 15 minutes de clics. Multipliez par 30 VM.

Une **cloud-image** est un disque `qcow2` contenant une distribution **déjà installée**,
sans mot de passe, sans clé SSH, sans hostname — volontairement « vierge ». Au premier
démarrage, **cloud-init** lit un support de configuration (chez Proxmox : un petit
CD-ROM ISO généré à la volée) et applique :

```
   ┌──────────────────┐        ┌──────────────────────────────┐
   │  Template        │        │  CD-ROM cloud-init (généré)  │
   │  (disque qcow2   │  +     │  · hostname                  │
   │   générique)     │        │  · user + clé SSH            │
   └────────┬─────────┘        │  · IP / gw / DNS             │
            │                  │  · paquets, scripts, fichiers│
            │  clone           └───────────────┬──────────────┘
            ▼                                  │
   ┌──────────────────────────────────────────▼───┐
   │  VM démarrée, configurée, joignable en SSH   │
   │              ⏱ ~15 secondes                  │
   └──────────────────────────────────────────────┘
```

**Le template ne change jamais.** Toute la personnalisation vit dans le CD-ROM
cloud-init, régénéré à chaque modification.

---

## 2. Fabriquer le template Debian 13 🐧

```bash
N=3                               # ⚠ VOTRE numéro d'élève
VMID=${N}90                       # ex. 390
IMG=/var/lib/vz/template/cloudimg/debian-13-genericcloud-amd64.qcow2
```

### 2.1 Personnaliser l'image avant même de la démarrer 🎩

`virt-customize` monte le qcow2 et y injecte des paquets. On gagne un boot.

```bash
apt install -y libguestfs-tools

cp $IMG /tmp/debian13-work.qcow2

virt-customize -a /tmp/debian13-work.qcow2 \
  --install qemu-guest-agent,curl,vim,htop,ca-certificates \
  --timezone "Pacific/Noumea" \
  --run-command 'systemctl enable qemu-guest-agent' \
  --run-command 'echo "PermitRootLogin prohibit-password" > /etc/ssh/sshd_config.d/10-lab.conf' \
  --truncate /etc/machine-id
```

🧠 **`--truncate /etc/machine-id`** est essentiel, mais pas pour la raison qu'on croit.

Le `machine-id` **ne détermine pas l'adresse MAC** — celle-ci est tirée au sort par
Proxmox, une par carte, à la création de la VM. Ce qu'il détermine, c'est le
**DUID/IAID** que `systemd-networkd` envoie comme *identifiant client* dans ses
requêtes DHCP (RFC 3315).

Or un serveur DHCP moderne indexe ses baux sur cet identifiant **avant** de regarder
la MAC. Deux clones aux MAC différentes mais au `machine-id` identique demandent donc
le **même bail** :

```
   clone A   MAC aa:bb:...:01   DUID dérivé de machine-id XYZ  ─┐
                                                                ├─► même bail → 10.3.10.100
   clone B   MAC aa:bb:...:02   DUID dérivé de machine-id XYZ  ─┘
```

Symptôme déroutant : deux VM aux MAC bien distinctes obtiennent la même adresse, et
`ip -br a` sur l'hôte n'explique rien. Un `/etc/machine-id` vide force systemd à en
régénérer un au premier boot, donc un DUID unique par clone.

🎁 Le même mécanisme explique les IP dupliquées après un `dd` de VM, ou après un clone
de conteneur : cherchez toujours `machine-id` avant de soupçonner le DHCP.

### 2.2 Créer la VM support

```bash
qm create $VMID \
  --name tpl-debian13-e$N \
  --pool eleve$N \
  --ostype l26 \
  --machine q35 \
  --cpu x86-64-v2-AES \
  --cores 2 --sockets 1 \
  --memory 2048 --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vint,firewall=1,mtu=1 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --serial0 socket --vga serial0 \
  --numa 1
```

🧠 Deux points importants :

- **`--cpu x86-64-v2-AES`** et non `host`. Un template destiné à un cluster doit
  produire des VM **migrables à chaud** entre nœuds au CPU différent. C'est le
  compromis évoqué au TP 03 : on perd 2 % de perf, on gagne la migration.
- **`--serial0 socket --vga serial0`** : les cloud-images sortent leurs logs de boot
  sur la console série. Sans ça, l'écran noVNC reste noir et vous croyez que la VM
  est plantée alors qu'elle boote très bien.

### 2.3 Importer le disque

```bash
qm importdisk $VMID /tmp/debian13-work.qcow2 local-lvm
qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0,discard=on,ssd=1,iothread=1
```

> Sur PVE 9, `qm set $VMID --scsi0 local-lvm:0,import-from=/tmp/debian13-work.qcow2`
> fait l'import et l'attachement en une seule commande. Les deux approches marchent.

### 2.4 Ajouter le lecteur cloud-init et le boot

```bash
qm set $VMID --ide2 local-lvm:cloudinit
qm set $VMID --boot order='scsi0'
```

### 2.5 Valeurs par défaut du cloud-init

```bash
qm set $VMID \
  --ciuser eleve \
  --cipassword "$(openssl passwd -6 'Formation2026!')" \
  --sshkeys /root/.ssh/authorized_keys \
  --ciupgrade 1 \
  --nameserver "1.1.1.1 8.8.8.8" \
  --searchdomain lab.local \
  --ipconfig0 ip=dhcp
```

🧠 **Pourquoi `openssl passwd -6` ?** Proxmox recopie la valeur de `--cipassword`
telle quelle dans le champ `password:` du user-data, et cloud-init accepte **aussi
bien un mot de passe en clair qu'un hash** — les deux fonctionnent. Passer un hash
n'est donc pas obligatoire, c'est un **choix d'hygiène** :

```bash
qm config <vmid> | grep cipassword     # en clair : visible par tout PVEAuditor
qm cloudinit dump <vmid> user          # et recopié tel quel dans le user-data
```

Le mot de passe en clair traîne dans `/etc/pve/qemu-server/<vmid>.conf`, donc dans
les sauvegardes de configuration, et dans le state Terraform si vous le pilotez
depuis là. Le hash, lui, ne se rejoue pas ailleurs.

🪤 En revanche, **`-6` (SHA-512) n'est pas négociable** : un hash `-1` (MD5) ou
`-5` (SHA-256) sera accepté par certaines distributions et refusé par d'autres.

### 2.6 Agrandir le disque et sceller

Une cloud-image fait 2-3 Go. On l'agrandit **avant** de faire le template :
cloud-init étendra la partition automatiquement au premier boot.

```bash
qm resize $VMID scsi0 20G
qm template $VMID
qm config $VMID
```

✅ Dans l'interface, l'icône de la VM devient un template (petit écran gris).

---

## 3. Le script fourni 🚀

Tout ceci est industrialisé dans `lab/scripts/build-template.sh`.

```bash
N=3     # ⚠ VOTRE numéro d'élève
# Sur le nœud Proxmox
cd /root
git clone <url-du-depot> formation
cd formation

./lab/scripts/build-template.sh --help

# Les trois templates de la formation, d'un coup
./lab/scripts/build-template.sh --eleve $N --os debian13 --vmid ${N}90
./lab/scripts/build-template.sh --eleve $N --os ubuntu2604 --vmid ${N}91
./lab/scripts/build-template.sh --eleve $N --os rocky10 --vmid ${N}92

qm list | grep -i tpl
```

Lisez le script : il ne fait rien de plus que ce que vous venez de taper, avec la
gestion d'erreurs en plus.

---

## 4. Spécificités par distribution 🐧🦎🪨

| | Debian 13 | Ubuntu 26.04 | Rocky Linux 10 |
|---|---|---|---|
| Format image | `.qcow2` | `.img` (qcow2 déguisé) | `.qcow2` |
| Utilisateur par défaut | `debian` | `ubuntu` | `rocky` |
| Agent QEMU | à installer | à installer | à installer |
| Gestion réseau | ifupdown / cloud-init | **netplan** | **NetworkManager** |
| Pare-feu par défaut | aucun | aucun | **firewalld actif** ⚠️ |
| SELinux | non | non | **enforcing** ⚠️ |
| Paquets | `apt` | `apt` | `dnf` |

🪤 **Rocky Linux, les deux pièges** :

```bash
# firewalld bloque tout sauf SSH → vos tests HTTP échouent
virt-customize -a rocky.qcow2 --run-command 'systemctl disable firewalld'
# (en production : on configure firewalld, on ne le désactive pas)

# SELinux relabel : si vous avez modifié des fichiers hors contexte
virt-customize -a rocky.qcow2 --run-command 'touch /.autorelabel'
```

Commandes d'installation de l'agent :

```bash
# Debian / Ubuntu
--install qemu-guest-agent
# Rocky
--install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent'
```

---

## 5. Cloner et tester ⚡

```bash
N=3     # ⚠ VOTRE numéro d'élève
# Clone lié (linked clone) : instantané, ne duplique pas le disque
qm clone ${N}90 ${N}20 --name app01-e$N --pool eleve$N

# On le branche dans la zone interne créée au TP 08, en IP statique cette fois
qm set ${N}20 --net0 virtio,bridge=vint,firewall=1,mtu=1
qm set ${N}20 --ipconfig0 ip=10.$N.10.50/24,gw=10.$N.10.1
qm set ${N}20 --nameserver 10.$N.10.1 --searchdomain lab.local
qm set ${N}20 --ciuser eleve --sshkeys /root/.ssh/authorized_keys
qm set ${N}20 --tags "debian,interne,app"

time qm start ${N}20
```

Suivez le boot en direct sur la console série :

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm terminal ${N}20        # Ctrl+O pour sortir
```

Puis :

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm agent ${N}20 network-get-interfaces | jq -r '.[]|select(.name=="eth0")|."ip-addresses"[]."ip-address"'
# depuis srv01 (déjà dans la zone interne) ou depuis le nœud
ssh eleve@10.$N.10.50 'hostname; cloud-init status --long; df -h /'
```

✅ `cloud-init status` doit renvoyer `status: done`.

### Clone lié vs clone complet

```
   LINKED CLONE (--full 0)              FULL CLONE (--full 1)
   ─────────────────────────            ──────────────────────
   template ◄── copy-on-write           template     copie complète
       ▲          VM1                                   VM1
       ├───────── VM2                                   VM2
       └───────── VM3                                   VM3

   ⚡ instantané, économe en disque     🐢 lent, consomme la taille pleine
   ❌ le template devient indestructible ✅ VM totalement indépendante
   ❌ pas de migration vers un autre     ✅ migrable partout
      stockage sans conversion
```

🪤 Un **linked clone** ne fonctionne que sur les stockages qui supportent le COW
(LVM-thin, ZFS, qcow2 sur `dir`). Sur du LVM épais ou de l'iSCSI : full clone obligatoire.

🚨 **Et surtout : un clone lié sur stockage local ne migre pas.** Proxmox refuse net :

```
can't migrate 'local-lvm:base-390-disk-0/vm-320-disk-0' as it's a clone of 'base-390-disk-0'
```

L'image de base n'existe pas sur le nœud cible, et Proxmox ne va pas la copier au
passage. **Retenez-le pour le jour 4** : les VM des TP 17 et 19 sont clonées en
`--full 1`, ou bien leur disque part sur Ceph (`qm move-disk`) avant toute migration.

---

## 6. Déboguer cloud-init 🔧

Le CD-ROM cloud-init généré est visible :

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm cloudinit dump ${N}20 user
qm cloudinit dump ${N}20 network
qm cloudinit dump ${N}20 meta
```

Dans la VM :

```bash
cloud-init status --long
cloud-init schema --system --annotate      # valide votre YAML
sudo cat /var/log/cloud-init.log | tail -50
sudo cat /var/log/cloud-init-output.log    # sortie des commandes runcmd
ls /var/lib/cloud/instance/
```

### Rejouer cloud-init (sans recréer la VM)

```bash
# Dans la VM
sudo cloud-init clean --logs --reboot
```

🪤 **Le piège n°1 de cloud-init** : il ne s'exécute qu'**une fois par instance-id**.
Vous modifiez `--ipconfig0`, vous redémarrez, rien ne change ? Normal. Il faut soit
`cloud-init clean`, soit — plus simple côté Proxmox — que le lecteur cloud-init soit
régénéré (`qm set` le fait automatiquement, mais la VM doit être **arrêtée puis
démarrée**, pas juste redémarrée depuis l'intérieur).

---

## 7. Les trois templates de la formation 📚

À la fin de ce TP, vous devez avoir :

| VMID | Nom | OS | Rôle dans la suite |
|---|---|---|---|
| `N90` | `tpl-debian13-eN` | Debian 13 | serveurs internes |
| `N91` | `tpl-ubuntu2604-eN` | Ubuntu 26.04 | serveurs web / DMZ |
| `N92` | `tpl-rocky10-eN` | Rocky Linux 10 | pour varier, et souffrir un peu 🪨 |

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm list | grep -E "${N}9[0-2]"
```

---

## ✅ Checklist de validation

- [ ] Les 3 templates existent et sont bien marqués « template »
- [ ] Un clone de `N90` démarre en moins de 30 secondes
- [ ] `cloud-init status` renvoie `done` dans le clone
- [ ] SSH par clé fonctionne sans mot de passe
- [ ] Le disque est bien à 20 Go (partition étendue automatiquement)
- [ ] `qm agent <vmid> ping` répond
- [ ] Je sais expliquer pourquoi on tronque `/etc/machine-id`
- [ ] Je sais expliquer pourquoi le template est en `x86-64-v2-AES` et pas `host`

---

## 🎁 Bonus

1. Créez un template **Alpine** en VM (pas en LXC) à partir de la
   `alpine-virt` cloud image. Alpine utilise `tiny-cloud`, pas `cloud-init` :
   observez les différences.
2. Ajoutez un **vendor-data** commun à toutes vos VM
   (`/var/lib/vz/snippets/vendor-common.yaml`) qui installe systématiquement
   `node_exporter`. Appliquez avec `qm set <vmid> --cicustom "vendor=local:snippets/vendor-common.yaml"`.
3. Mesurez : `time qm clone N90 N29 --full 0` vs `--full 1`. Puis `lvs` pour voir
   la différence d'occupation.

➡️ Suite : [TP 11 — Terraform : déployer dans les réseaux SDN](11-terraform-vms-sdn.md)
