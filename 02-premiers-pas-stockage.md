# TP 02 — Premiers pas et stockages 💾

⏱️ **1 h 30** · Jour 1

Objectif : comprendre l'organisation de Proxmox, maîtriser les types de stockage, et
préparer le terrain (ISO, templates, pools, snippets) pour tous les TP suivants.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvesm.html>

---

## 1. La carte de l'interface 🗺️

```
   Datacenter                       ← tout ce qui est CLUSTER-WIDE
   ├── Search / Summary
   ├── Options                      ← politiques par défaut
   ├── Storage                      ← LES STOCKAGES (définis ici, pas par nœud !)
   ├── Backup / Replication
   ├── Permissions ├ Users ├ API Tokens ├ Roles ├ Pools
   ├── HA          ├ Groups ├ Resources
   ├── SDN         ← Zones / VNets / Options / IPAM / DNS / Fabrics ★ jours 2-4
   ├── Firewall    ├ Options ├ Rules ├ Security Group ├ Alias ├ IPSet
   ├── Ceph
   └── pveN                         ← ce qui est PROPRE AU NŒUD
       ├── Summary / Notes
       ├── Shell            ← console root dans le navigateur
       ├── System           ← Network, Certificates, DNS, Hosts, Time, Syslog
       ├── Updates          ← Repositories
       ├── Firewall
       ├── Disks            ← LVM, LVM-Thin, Directory (pas de ZFS ici)
       ├── Ceph
       ├── Replication
       └── <vmid> VM / CT
```

🧠 **La distinction clé** : un **stockage** est déclaré au niveau *Datacenter* mais peut
être restreint à certains nœuds. C'est cette abstraction qui permettra, au jour 4, de
migrer une VM d'un nœud à l'autre : les deux nœuds connaissent un stockage du même nom.

---

## 2. Les types de stockage 🧱

| Type | Partagé ? | Snapshot | Contenu supporté | Notes |
|---|:---:|:---:|---|---|
| `dir` (Directory) | non* | via qcow2 | tout | Simple ; stocke des **fichiers** |
| `lvm` | non | non** | disques VM/CT | Rapide, brut |
| `lvmthin` | non | **oui** | disques VM/CT | Le défaut d'une install ext4 |
| `zfspool` | non | **oui** | disques VM/CT | Snapshots + réplication `zfs send` — **non utilisé dans cette formation** |
| `nfs` | **oui** | via qcow2 | tout | ⭐ jour 4 |
| `cifs` | **oui** | via qcow2 | tout | SMB |
| `iscsi` / `iscsidirect` | **oui** | non | disques VM | SAN bloc |
| `cephfs` / `rbd` | **oui** | **oui** | tout / disques | Le stockage distribué de référence |
| `pbs` | **oui** | n/a | backup | ⭐ jour 4 |

\* sauf s'il pointe vers un montage partagé, avec l'option `shared`.
\** PVE 9 a introduit les snapshots sur LVM épais partagé (via volume chain) —
utile en SAN, mais ce n'est pas le sujet ici.

### Les « content types »

Un stockage déclare ce qu'il accepte :

| Content | Contient |
|---|---|
| `images` | disques de VM |
| `rootdir` | disques de conteneurs LXC |
| `iso` | images ISO |
| `vztmpl` | templates de conteneurs LXC |
| `backup` | archives `vzdump` |
| `snippets` | fichiers cloud-init, hookscripts ⭐ |
| `import` | images à importer (OVA/OVF, disques) |

🪤 **Erreur n°1 des débutants** : « je ne vois pas mon ISO dans la liste » →
le stockage n'a pas le content type `iso` coché.

---

## 3. Inventaire de l'existant 🖥️

```bash
pvesm status
cat /etc/pve/storage.cfg
lsblk
vgs ; lvs
df -h /var/lib/vz
```

Sortie typique sur une install ext4 :

```
Name             Type     Status   Total       Used   Available  %
local            dir      active   ...
local-lvm        lvmthin  active   ...
```

- **`local`** → `/var/lib/vz`, type `dir` : ISO, templates LXC, backups, snippets.
- **`local-lvm`** → volume LVM-thin : les disques des VM et CT.

---

## 4. Ajouter le content `snippets` sur `local` 🔧

Indispensable pour les fichiers cloud-init personnalisés des TP 10 et 11.

🌐 `Datacenter → Storage → local → Edit → Content` : cocher **Snippets**.

Ou en CLI :

```bash
pvesm set local --content iso,vztmpl,backup,snippets
mkdir -p /var/lib/vz/snippets
pvesm status --content snippets
```

---

## 5. Créer un stockage supplémentaire 🆕

🧠 **Notre choix pour toute la formation** : on reste sur les deux stockages créés par
l'installateur — `local` (type `dir`) et **`local-lvm` (type `lvmthin`)**. Pas de ZFS :
voir [TP 01 §3.1](01-installation-proxmox.md). Le stockage partagé arrivera au jour 3
(NFS depuis votre poste) et au jour 4 (**Ceph**).

### Cas A — vous avez un second disque physique 🎁

Réservez-le pour Ceph au TP 18 (`pveceph osd create /dev/sdb`) : ce sera bien plus
propre que la chirurgie LVM. **Ne le formatez pas maintenant.**

```bash
lsblk                       # identifiez-le et notez son nom
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

Si vous voulez tout de même un second pool LVM-thin pour expérimenter :

```bash
wipefs -a /dev/sdb          # ⚠ efface toute signature de FS existante
pvcreate /dev/sdb
vgcreate vg-data /dev/sdb
lvcreate -l 90%FREE --thinpool data vg-data
pvesm add lvmthin data-thin --vgname vg-data --thinpool data --content images,rootdir
```

### Cas B — un seul disque (le cas courant)

On ajoute simplement un stockage `dir`, utile pour des ISO ou des dumps ponctuels.

```bash
mkdir -p /var/lib/vz-extra
pvesm add dir extra --path /var/lib/vz-extra \
      --content iso,vztmpl,backup,snippets --shared 0
pvesm status
```

### Inspecter le pool LVM-thin — à connaître par cœur 🎯

```bash
lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent
vgs -o vg_name,vg_size,vg_free
```

🚨 **`data_percent` est la métrique la plus importante de votre hyperviseur.**
Au-delà de 95 %, les volumes passent en lecture seule et **vos VM se corrompent**.
Surveillez-la comme vous surveillez `df -h`.

🧠 Notez aussi `vg_free` : c'est l'espace non alloué du groupe de volumes. S'il est à
zéro, le TP 18 (Ceph) demandera de détruire et recréer le pool thin — **un thin pool ne
peut pas être réduit**. Si vous voyez de l'espace libre ici, c'est que vous avez bien
réglé `maxvz` à l'installation. 👏

---

## 6. Télécharger les images dont on aura besoin ⬇️

### 6.1 ISO Debian 13 (pour le TP 03)

🌐 `pveN → local → ISO Images → Download from URL` puis :

```
https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.x.0-amd64-netinst.iso
```

Ou en CLI :

```bash
cd /var/lib/vz/template/iso
# Adaptez le numéro de version mineure à ce qui est publié
curl -fLO https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso
ls -lh
```

### 6.2 Templates LXC (pour le TP 05)

```bash
pveam update
pveam available --section system | grep -Ei 'alpine|debian|ubuntu|rocky'
```

```bash
# Prenez le nom exact retourné par la commande précédente
pveam download local alpine-3.22-default_20250617_amd64.tar.xz
pveam download local debian-13-standard_13.0-1_amd64.tar.zst
pveam list local
```

### 6.3 Cloud-images (pour les TP 10 et 11)

```bash
mkdir -p /var/lib/vz/template/cloudimg && cd $_

# Debian 13 « Trixie »
curl -fLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2

# Ubuntu 26.04 LTS
curl -fL -o ubuntu-26.04-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img

# Rocky Linux 10
curl -fLO https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2

ls -lh
```

> 💡 Si un lien a bougé, cherchez le répertoire parent : les distributions réorganisent
> régulièrement. Vérifiez toujours les checksums publiés à côté (`SHA256SUMS`).

🧠 **ISO vs cloud-image** :

```
   ISO netinst                       Cloud image (qcow2)
   ───────────────                   ─────────────────────
   installateur interactif           déjà installée
   ~20 min par VM                    prête en 15 secondes
   configuration manuelle            configurée par cloud-init au 1er boot
   → apprentissage, cas particuliers → industrialisation ★
```

---

## 7. Créer un pool de ressources 📁

Un **pool** regroupe VM, CT et stockages pour déléguer des droits d'un bloc.

```bash
pvesh create /pools --poolid eleveN --comment "Ressources de l'élève N"
pvesh get /pools
```

Toutes vos VM iront dans ce pool. Au jour 4, dans un cluster à 6, vous verrez
immédiatement ce qui vous appartient.

---

## 8. Explorer l'API et la CLI 🔍

Trois façons de faire la même chose. Sachez basculer entre les trois.

```bash
# Navigation interactive dans l'API, comme un système de fichiers
pvesh ls /nodes
pvesh get /nodes/pveN/status --output-format yaml
pvesh get /cluster/resources --type vm

# Les commandes métier
pvesm status          # stockages
qm list               # VM
pct list              # conteneurs
pveperf               # petit benchmark (I/O, CPU)
```

🧠 **Tout ce que fait l'interface web passe par l'API.** Ouvrez les outils de
développement de votre navigateur (F12 → Réseau) pendant que vous cliquez : vous
verrez les appels `POST /api2/extjs/...`. C'est *le* réflexe pour découvrir comment
automatiser une action que vous ne savez faire qu'en clic.

---

## 9. Sauvegarder la configuration du nœud 🗃️

```bash
tar czf /root/pve-config-$(date +%F).tgz \
    /etc/pve /etc/network/interfaces /etc/hosts /etc/apt/sources.list.d
ls -lh /root/pve-config-*.tgz
```

Récupérez-la sur votre PC :

```bash
scp root@192.168.50.1N:/root/pve-config-*.tgz ~/ProxmoxFormation/backup-conf/
```

---

## ✅ Checklist de validation

- [ ] `pvesm status` affiche au moins `local` et un stockage pour les disques
- [ ] `local` accepte le content `snippets`
- [ ] L'ISO Debian 13 est visible dans `local → ISO Images`
- [ ] Au moins un template LXC Alpine est téléchargé (`pveam list local`)
- [ ] Les 3 cloud-images sont dans `/var/lib/vz/template/cloudimg`
- [ ] Le pool `eleveN` existe
- [ ] `pvesh ls /nodes` et `qm list` répondent
- [ ] La sauvegarde de config est sur mon PC

---

## 🎁 Bonus

1. Comparez `qm list` et `pvesh get /cluster/resources --type vm`. Lequel donne le plus
   d'informations ? Lequel fonctionnera à travers tout le cluster demain ?
2. `pvesm alloc local-lvm 9999 vm-9999-disk-0 1G` puis `lvs` — observez le volume créé,
   et supprimez-le avec `pvesm free local-lvm:vm-9999-disk-0`.
3. Lisez `/etc/pve/.version`, `/etc/pve/.members`, `/etc/pve/.vmlist` : trois fichiers
   virtuels générés par pmxcfs. Ils vont devenir très parlants au jour 4.

➡️ Suite : [TP 03 — Première VM Debian 13 via ISO netinstall](03-vm-iso-debian.md)
