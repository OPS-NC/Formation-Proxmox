# TP 14 — Un serveur NFS sur votre poste Ubuntu 💾

⏱️ **45 min** · Jour 3

Objectif : transformer votre PC de travail en serveur NFS, l'ajouter comme stockage
Proxmox, et comprendre ce que le stockage réseau apporte — et ce qu'il coûte.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvesm.html#storage_nfs>

---

## 1. Pourquoi votre PC, et pas une VM ? 🧠

Un serveur NFS hébergé dans une VM **sur le nœud qu'il doit servir**, c'est un serpent
qui se mord la queue : si le nœud tombe, le stockage tombe avec lui. Votre PC Ubuntu,
lui, est une machine **extérieure à l'hyperviseur**. C'est exactement la position d'un
NAS ou d'une baie de stockage.

```
   ┌──────────────────────────────────────────────────────────────┐
   │                LAN salle  172.30.30.0/24                     │
   │                                                              │
   │   ┌──────────────┐                    ┌──────────────┐       │
   │   │  PC Ubuntu   │                    │  Nœud pve    │       │
   │   │     $PC      │   NFS v4 / 2049    │    $PVE      │       │
   │   │              │◄──────────────────►│              │       │
   │   │              │                    │  /mnt/pve/   │       │
   │   │  /srv/nfs/   │                    │   nfs-pc/    │       │
   │   │  ├─ images/  │                    │              │       │
   │   │  ├─ dump/    │                    │              │       │
   │   │  ├─ template/│                    │              │       │
   │   │  └─ snippets/│                    │              │       │
   │   └──────────────┘                    └──────────────┘       │
   └──────────────────────────────────────────────────────────────┘
```

🧠 **Ce n'est pas une architecture de production** — un poste de travail n'a ni
redondance, ni onduleur, ni disques d'entreprise, et vous allez l'éteindre ce soir.
Mais ce sont **exactement les mêmes mécanismes** qu'une vraie baie NFS : exports,
options de montage, `no_root_squash`, gestion du disque plein, comportement quand le
serveur disparaît. Tout ce que vous apprenez ici se transpose tel quel.

Le vrai stockage partagé du lab, redondé et sans point de défaillance unique, ce sera
**Ceph** au TP 18.

---

## 2. Ce que le stockage réseau change 📊

| | `local-lvm` (LVM-thin) | `nfs-pc` |
|---|---|---|
| Performance | ⭐⭐⭐ disque local | ⭐ limité par le lien 1 Gb/s |
| Format des disques | volume bloc | fichier **`.qcow2`** |
| Snapshots | ✅ (LVM-thin) | ✅ (qcow2) |
| Partagé entre nœuds | ❌ | ✅ |
| Migration à chaud | copie du disque | **quasi instantanée** |
| ISO et templates | à dupliquer par nœud | ⭐ **une seule copie** |
| Point de défaillance unique | non | **oui** |

👉 L'usage le plus rentable du NFS dans ce lab : **les ISO, les templates LXC, les
snippets cloud-init et les sauvegardes**. Pour les disques de VM, on s'en servira le
temps de la démonstration, puis Ceph prendra le relais.

---

## 3. Installer le serveur NFS sur votre PC 💻

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
systemctl status nfs-server --no-pager | head -5
```

### Créer l'arborescence

```bash
# ⚠ Ces noms ne sont pas arbitraires : c'est le LAYOUT attendu par Proxmox.
sudo mkdir -p /srv/nfs/{images,dump,snippets,template/{iso,cache}}
sudo chown -R nobody:nogroup /srv/nfs
sudo chmod -R 0777 /srv/nfs
ls -lR /srv/nfs | head -20
```

| Répertoire | Contenu | Type de `--content` |
|---|---|---|
| `images/` | disques de VM **et** rootfs de conteneurs | `images`, `rootdir` |
| `dump/` | archives `vzdump` | `backup` |
| `template/iso/` | images ISO | `iso` |
| `template/cache/` | templates LXC | `vztmpl` |
| `snippets/` | user-data / vendor-data cloud-init | `snippets` |

🧠 **Proxmox créerait ces dossiers tout seul** au premier usage. On les pré-crée pour
deux raisons : fixer les droits (`nobody:nogroup`, `0777`) une bonne fois — sinon le
premier écrit les crée en `root:root` — et **voir la structure d'un stockage Proxmox**,
identique sur `dir`, `nfs` et `cifs`. C'est aussi ce qui vous permettra, au TP 15, de
comprendre où PBS range quoi.

🪤 Ne cherchez pas de dossier `iso/` ou `backup/` : ils s'appellent `template/iso/`
et `dump/`. Une erreur de nommage ici donne un stockage qui « apparaît vide » dans
l'interface, sans le moindre message d'erreur.

### Déclarer l'export

```bash
PVE=172.30.30.___                 # ⚠ l'IP de VOTRE nœud (TP 00 §2)
sudo tee /etc/exports.d/proxmox-lab.exports >/dev/null <<EOF
# Export pour la formation Proxmox
# ⚠ no_root_squash : Proxmox écrit en root pour créer les disques de VM.
#   On l'accepte, MAIS on restreint l'export à la seule IP du nœud.
/srv/nfs  $PVE(rw,sync,no_subtree_check,no_root_squash)
EOF

cat /etc/exports.d/proxmox-lab.exports    # ⭐ le shell a remplacé $PVE par l'IP littérale
sudo exportfs -ra
sudo exportfs -v
```

Sortie attendue (ici avec `.151` en exemple) :

```
/srv/nfs        172.30.30.151(sync,wdelay,hide,no_subtree_check,sec=sys,rw,
                secure,no_root_squash,no_all_squash)
```

🪤 Un fichier d'export ne connaît pas vos variables shell : c'est le heredoc (sans
quotes autour de `EOF`) qui a substitué `$PVE`. Si vous voyez `$PVE` en toutes lettres
dans le fichier, la variable n'était pas définie — corrigez avant `exportfs`.

🪤 **`no_root_squash` est un compromis assumé.** Par défaut, NFS transforme le `root`
du client en `nobody` — mais Proxmox a besoin d'écrire en root pour créer les disques.
On désactive donc le squash, **et en compensation on restreint l'export à une seule
adresse IP**. Sur une infrastructure réelle, ce partage aurait son propre VLAN de
stockage, isolé de tout le reste.

> 💡 Pour partager avec tous les nœuds (utile au jour 4) : remplacez `$PVE`
> par `172.30.30.0/24`. Mesurez la différence de posture de sécurité — vous venez
> d'ouvrir un accès root en écriture à tout le réseau.

### Forcer NFSv4 uniquement

```bash
sudo tee /etc/nfs.conf.d/lab.conf >/dev/null <<'EOF'
[nfsd]
vers3 = n
vers4 = y
vers4.2 = y
EOF

sudo systemctl restart nfs-server
cat /proc/fs/nfsd/versions
```

🧠 **Pourquoi NFSv4 seulement ?** La v4 n'utilise qu'**un seul port, 2049/tcp**.
La v3 a besoin de `rpcbind`, `mountd` et `statd` sur des ports variables : un
cauchemar à filtrer. Forcez toujours la v4.

### Le pare-feu de votre PC

```bash
sudo ufw status
# S'il est actif :
sudo ufw allow from $PVE to any port 2049 proto tcp comment 'NFS Proxmox'
sudo ufw status numbered
```

---

## 4. Automatiser avec Ansible 🎼

On réutilise le rôle `nfs` fourni dans `lab/ansible` — cette fois joué sur **`localhost`**.

`lab/ansible/inventory/local.yml` :

```yaml
---
all:
  hosts:
    poste-ubuntu:
      ansible_host: localhost
      ansible_connection: local
  vars:
    nfs_manage_disk: false                   # pas de disque dédié : on utilise /srv
    nfs_root: "/srv/nfs"
    nfs_allowed_network: "172.30.30.151"     # ⚠ l'IP de VOTRE nœud ($PVE)
    # nfs_subdirs : la valeur par défaut du rôle est déjà le layout Proxmox
```

```bash
cd ~/ProxmoxFormation/lab/ansible
ansible-playbook -i inventory/local.yml nfs-local.yml --ask-become-pass
```

🧠 **Le rôle est le même**, seule la cible change. C'est tout l'intérêt d'un rôle bien
écrit : il ne suppose rien sur *où* il tourne. La variable `nfs_manage_disk: false`
saute les tâches de partitionnement, inutiles ici.

---

## 5. Vérifier depuis le nœud Proxmox 🖥️

Relevez d'abord l'adresse de votre poste, **sur le poste** :

```bash
hostname -I | awk '{print $1}'        # → notez-la, c'est votre $PC
```

Puis, **sur le nœud Proxmox** :

```bash
PC=172.30.30.___                  # ⚠ l'IP relevée ci-dessus

apt install -y nfs-common
showmount -e $PC
```

```
Export list for 172.30.30.35:
/srv/nfs 172.30.30.151
```

Test manuel **avant** de déclarer le stockage — toujours :

```bash
PC=172.30.30.___                  # ⚠ l'IP de votre poste
mkdir -p /mnt/test-nfs
mount -t nfs -o vers=4.2 $PC:/srv/nfs /mnt/test-nfs
touch /mnt/test-nfs/ok-depuis-pve && ls -l /mnt/test-nfs/
rm /mnt/test-nfs/ok-depuis-pve
umount /mnt/test-nfs
```

🪤 Si `mount` échoue :

| Erreur | Piste |
|---|---|
| `Connection refused` | `nfs-server` arrêté sur le PC |
| `access denied by server` | L'IP du nœud n'est pas dans l'export |
| `No route to host` | `ufw` sur le PC bloque le port 2049 |
| `Permission denied` en écriture | `no_root_squash` absent, ou droits sur `/srv` |

```bash
# Côté PC, en cas de doute
sudo journalctl -u nfs-server -n 30 --no-pager
sudo exportfs -v
ss -tlnp | grep 2049
```

---

## 6. Déclarer le stockage dans Proxmox ⭐

🌐 `Datacenter → Storage → Add → NFS`

| Champ | Valeur |
|---|---|
| ID | `nfs-pc` |
| Server | l'IP de **votre poste** (`hostname -I`) |
| Export | `/srv/nfs` — choisi dans la liste déroulante |
| Content | `Disk image`, `Container`, `ISO image`, `Backup`, `Snippets` |
| Nodes | `All` (il n'y en a qu'un pour l'instant) |
| Enable | ✅ |
| Options | `vers=4.2` |
| Prune | `keep-last=3` |

```bash
PC=172.30.30.___                  # ⚠ l'IP de VOTRE poste
pvesm add nfs nfs-pc \
  --server $PC \
  --export /srv/nfs \
  --content images,rootdir,iso,backup,snippets \
  --options vers=4.2 \
  --prune-backups 'keep-last=3'

pvesm status
cat /etc/pve/storage.cfg
df -h | grep nfs
mount | grep nfs
```

🧠 **Pas de `--nodes` aujourd'hui, mais retenez l'option.** Un stockage est déclaré
au niveau *Datacenter* ; aux jours 1-3 il n'y a qu'un nœud, la restriction est inutile.
Au TP 16, en cluster, elle deviendra **indispensable** (`--nodes $(hostname)`) :
sans elle, les six nœuds tenteraient de monter votre partage — qui n'autorise que
votre IP — et le signaleraient en erreur toutes les 30 secondes dans l'interface de
tout le monde.

🧠 **Ce stockage est le seul qui survivra à la réinstallation du TP 16.** Il vit sur
votre PC, pas sur le nœud : les ISO, les snippets et les `vzdump` que vous y déposez
seront encore là au jour 4. Tout ce qui est sur `local` et `local-lvm` disparaîtra.

---

## 7. L'utiliser 🚀

### Déplacer un disque de VM, à chaud

```bash
qm move-disk 120 scsi0 nfs-pc --delete 1      # cloud01, clonée au TP 10
qm config 120 | grep scsi0
ls -lh /mnt/pve/nfs-pc/images/120/
```

🧠 Observez le format : sur un stockage `nfs` ou `dir`, le disque est un **fichier
`.qcow2`** dans `images/<vmid>/`. Sur `local-lvm`, c'était un volume bloc
(`/dev/pve/vm-120-disk-0`). C'est cette différence qui permet les snapshots qcow2 sur
NFS — et qui explique la légère perte de performance.

### Comparer les débits

```bash
# Disque sur local-lvm
qm move-disk 120 scsi0 local-lvm --delete 1
ssh eleve@10.10.10.50 \
  'dd if=/dev/zero of=/tmp/t bs=1M count=512 oflag=direct conv=fsync; rm /tmp/t'

# Le même disque sur NFS
qm move-disk 120 scsi0 nfs-pc --delete 1
ssh eleve@10.10.10.50 \
  'dd if=/dev/zero of=/tmp/t bs=1M count=512 oflag=direct conv=fsync; rm /tmp/t'
```

Sur un lien 1 Gb/s, attendez-vous à plafonner autour de **110 Mo/s** en NFS, contre
plusieurs centaines de Mo/s en local. C'est la limite du réseau, pas du protocole.

### Y mettre les ISO, templates et snippets

C'est l'usage le plus utile.

```bash
# Déplacer l'ISO Debian vers le NFS
mv /var/lib/vz/template/iso/debian-13*.iso /mnt/pve/nfs-pc/template/iso/
pvesm list nfs-pc

# Un snippet cloud-init partagé
cp /root/formation/lab/cloud-init/vendor-data-common.yaml /mnt/pve/nfs-pc/snippets/
qm set 120 --cicustom "vendor=nfs-pc:snippets/vendor-data-common.yaml"
qm cloudinit dump 120 vendor | head        # Proxmox le lit bien depuis le NFS

# … puis on détache : au TP 16, le stockage s'appellera nfs-<nœud>, et une VM qui
# référence un stockage inexistant refuse de démarrer.
qm set 120 --delete cicustom
```

### Une sauvegarde

```bash
vzdump 120 --storage nfs-pc --mode snapshot --compress zstd
ls -lh /mnt/pve/nfs-pc/dump/
```

🧠 Cette archive est sur votre PC : c'est **le** moyen de faire passer une machine
au-delà de la réinstallation du TP 16 (`qmrestore` depuis `nfs-pc`, une fois le
cluster monté).

---

## 8. Le test le plus instructif : débrancher le stockage 🔥

**À faire, vraiment.** C'est l'incident que vous vivrez en production.

```bash
# 1. Une VM tourne, son disque est sur le NFS (il y est déjà depuis le §7)
qm config 120 | grep scsi0                    # → nfs-pc:120/vm-120-disk-0.qcow2
qm status 120 | grep -q running || qm start 120
```

```bash
# 2. Sur votre PC : couper le serveur NFS
sudo systemctl stop nfs-server
```

Observez, sur le nœud :

```bash
qm status 120
ls /mnt/pve/nfs-pc/            # ⏳ gèle
dmesg -T | tail -20            # « nfs: server ... not responding, still trying »
pvesm status                   # nfs-pc en « inactive »
```

La VM ne plante pas : ses I/O sont **bloquées en attente**. C'est le comportement du
montage `hard` (le défaut), et c'est le bon : les écritures ne sont pas perdues, elles
patientent.

```bash
# 3. Rétablir
sudo systemctl start nfs-server
```

Le nœud reprend tout seul, et la VM continue comme si rien ne s'était passé.

🪤 **Ne mettez jamais l'option `soft` sur un montage qui porte des disques de VM.**
Avec `soft`, les I/O échouent après un délai au lieu d'attendre — le système de
fichiers de l'invité reçoit des erreurs d'écriture et se corrompt. `soft` est
acceptable pour un partage de fichiers en lecture, jamais pour du stockage bloc.

---

## 9. Ce que ça prépare 🔓

| Fonction | Sans stockage réseau | Avec NFS | Avec Ceph (TP 18) |
|---|---|---|---|
| Migration à chaud | copie du disque | quelques secondes | quelques secondes |
| ISO et templates | dupliqués par nœud | ⭐ une copie | une copie |
| Sauvegardes | par nœud | centralisées | centralisées |
| Haute disponibilité | impossible | possible, **avec un SPOF** | ✅ sans SPOF |
| Tolérance de panne | — | ❌ le serveur tombe, tout tombe | ✅ 3 copies |

👉 Le SPOF, c'est justement ce que **Ceph** élimine au **TP 18**. Gardez la comparaison
en tête : NFS = un serveur, simple, avec un point de défaillance unique. Ceph = trois
copies réparties, complexe, sans point de défaillance.

---

## ✅ Checklist de validation

- [ ] `nfs-kernel-server` tourne sur mon PC Ubuntu
- [ ] `/srv/nfs/` contient les sous-répertoires attendus
- [ ] `sudo exportfs -v` montre l'export restreint à l'IP de mon nœud
- [ ] Seul NFSv4 est actif (`cat /proc/fs/nfsd/versions`)
- [ ] `showmount -e <ip-pc>` fonctionne depuis le nœud
- [ ] Le montage manuel a été testé **avant** la déclaration du stockage
- [ ] Le stockage `nfs-pc` est `active` dans `pvesm status`
- [ ] J'ai déplacé un disque de VM vers le NFS et la VM fonctionne
- [ ] J'ai vu le disque sous forme de fichier `.qcow2`
- [ ] J'ai comparé les débits `local-lvm` vs NFS
- [ ] **J'ai coupé le serveur NFS et observé le gel puis la reprise** 🎯
- [ ] Je sais expliquer pourquoi `soft` est dangereux pour des disques de VM
- [ ] Je sais expliquer le compromis `no_root_squash`

---

## 🎁 Bonus

1. **Le disque plein** : `fallocate -l 40G /srv/nfs/gros`, puis essayez d'écrire
   depuis une VM. Observez le comportement de Proxmox et les messages du noyau.
   Nettoyez ensuite (`rm /srv/nfs/gros`). Ce genre d'incident arrive vraiment.
2. **CIFS/SMB** : ajoutez un second partage en Samba (`apt install samba`) et déclarez-le
   avec `pvesm add cifs`. Comparez les débits avec NFS.
3. **Les options de montage** : passez `--options vers=4.2,rsize=1048576,wsize=1048576`
   et re-mesurez avec `dd`. Documentez l'écart.
4. **Partager avec tout le cluster** : élargissez l'export à `172.30.30.0/24`, et au
   jour 4 déclarez le stockage sans `--nodes` : les six nœuds le montent. Puis expliquez
   pourquoi ce n'est **pas** une bonne idée en production (indice : qui éteint son PC
   à 18 h ?).

➡️ Suite : [TP 15 — Proxmox Backup Server](15-proxmox-backup-server.md)
