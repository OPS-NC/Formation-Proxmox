# TP 14 — Serveur NFS en Terraform + Ansible, puis stockage partagé 💾

⏱️ **1 h** · Jour 3

Objectif : assembler tout ce qu'on sait faire. Terraform crée une VM avec un disque
dédié, Ansible y installe un serveur NFS, et Proxmox l'ajoute comme **stockage
partagé** — celui qui rendra possible la migration à chaud du jour 4.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvesm.html#storage_nfs>

---

## 1. Pourquoi du stockage partagé ? 🧠

```
   STOCKAGE LOCAL                        STOCKAGE PARTAGÉ
   ──────────────                        ────────────────
   pve1        pve2                      pve1        pve2
    │           │                          │           │
   [VM]        (vide)                      └─────┬─────┘
    │                                            │
   disque local                            ┌─────┴──────┐
                                           │  NFS / Ceph│
   Migration = COPIER tout                 │    [VM]    │
   le disque (minutes, GB)                 └────────────┘

                                        Migration = déplacer
                                        seulement la RAM (secondes)
```

| | Local (LVM/ZFS) | Partagé (NFS/Ceph) |
|---|---|---|
| Performance | ⭐⭐⭐ | ⭐⭐ (dépend du réseau) |
| Migration à chaud | copie complète du disque | **quasi instantanée** |
| HA (redémarrage auto ailleurs) | ❌ impossible | ✅ |
| Point de défaillance unique | non | **oui, si non redondé** |
| Coût | inclus | serveur ou baie dédiés |

🧠 **Le NFS n'est pas la solution idéale** : notre serveur NFS est une VM, donc un
point de défaillance unique, et il tourne sur un nœud du cluster. En production on
utiliserait Ceph (distribué, sans SPOF) ou une baie redondée. Mais pour comprendre
les mécanismes — et pour un lab — c'est parfait, et ça se monte en une heure.

---

## 2. La cible 🎯

```
   ┌──────────────── LAN salle 192.168.50.0/24 ───────────────┐
   │                                                          │
   │   pve1   pve2   pve3   pve4   pve5   pve6                │
   │     │      │      │      │      │      │                 │
   │     └──────┴──────┴──┬───┴──────┴──────┘                 │
   │                      │  montages NFS                     │
   │              ┌───────┴────────┐                          │
   │              │  VM nfs-lab    │  192.168.50.40           │
   │              │  Debian 13     │                          │
   │              │  /srv/nfs/     │  disque dédié 60 Go      │
   │              │   ├─ images/   │  → disques de VM         │
   │              │   ├─ iso/      │  → ISO partagés          │
   │              │   └─ backup/   │  → sauvegardes vzdump    │
   │              └────────────────┘                          │
   └──────────────────────────────────────────────────────────┘
```

> 🤝 **TP en binôme ou désigné.** Un seul serveur NFS pour toute la salle. Le formateur
> désigne l'élève qui l'héberge (par ex. l'élève 1). Les autres suivent la
> construction et effectuent l'étape 6 (ajout du stockage) sur leur propre nœud.

---

## 3. Terraform : la VM et son disque 🏗️

`lab/terraform/04-nfs/main.tf` :

```hcl
resource "proxmox_virtual_environment_vm" "nfs" {
  name        = "nfs-lab"
  description = "Serveur NFS du lab — géré par Terraform"
  node_name   = var.pve_node
  vm_id       = 900                      # hors des plages élèves
  pool_id     = "eleve${var.eleve}"
  tags        = ["terraform", "nfs", "storage", "infra"]

  clone { vm_id = var.template_debian, full = true }   # full : pas de dépendance au template
  agent { enabled = true }

  cpu    { cores = 2, type = "x86-64-v2-AES" }
  memory { dedicated = 2048 }

  # Le disque de données, séparé du système
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 60
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Sur le LAN physique : tous les nœuds doivent le joindre
  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "192.168.50.40/24"
        gateway = "192.168.50.254"
      }
    }
    dns { servers = ["192.168.50.254"] }
    user_account { username = "eleve", keys = [var.ssh_public_key] }
  }

  lifecycle { prevent_destroy = true }     # filet de sécurité 🛟
}
```

🧠 **Trois décisions à comprendre :**

1. **`vmbr0` et pas un VNet SDN.** Le stockage doit être joignable par les six nœuds,
   depuis leur pile réseau *hôte*. Un VNet SDN est réservé aux guests. Mettre le NFS
   derrière du SNAT serait une très mauvaise idée.
2. **`full = true`.** Un linked clone dépend du template, qui est local à un nœud. Un
   serveur de stockage ne doit dépendre de rien.
3. **`prevent_destroy`.** Un `terraform destroy` distrait effacerait les disques de
   tout le monde. Cette ligne coûte trois secondes à écrire.

```bash
cd ~/ProxmoxFormation/lab/terraform/04-nfs
source ~/.config/pve/token.env
terraform init && terraform apply
```

---

## 4. Ansible : le rôle `nfs` 🎼

`lab/ansible/roles/nfs/tasks/main.yml` :

```yaml
---
- name: Installer le serveur NFS
  ansible.builtin.apt:
    name: [nfs-kernel-server, parted, xfsprogs]
    state: present
    update_cache: true

- name: Partitionner le disque de données
  community.general.parted:
    device: "{{ nfs_device }}"
    number: 1
    state: present
    fs_type: xfs
    part_end: "100%"

- name: Formater en XFS
  community.general.filesystem:
    fstype: xfs
    dev: "{{ nfs_device }}1"

- name: Monter le volume
  ansible.posix.mount:
    path: "{{ nfs_root }}"
    src: "{{ nfs_device }}1"
    fstype: xfs
    opts: defaults,noatime
    state: mounted

- name: Créer l'arborescence des exports
  ansible.builtin.file:
    path: "{{ nfs_root }}/{{ item }}"
    state: directory
    owner: nobody
    group: nogroup
    mode: "0777"
  loop: "{{ nfs_exports }}"

- name: Écrire /etc/exports
  ansible.builtin.template:
    src: exports.j2
    dest: /etc/exports
    mode: "0644"
  notify: recharger les exports

- name: Démarrer le serveur NFS
  ansible.builtin.service:
    name: nfs-server
    state: started
    enabled: true

- name: Vérifier les exports
  ansible.builtin.command: exportfs -v
  changed_when: false
  register: exp

- name: Afficher les exports
  ansible.builtin.debug:
    var: exp.stdout_lines
```

`roles/nfs/templates/exports.j2` :

```
{% for e in nfs_exports %}
{{ nfs_root }}/{{ e }}  {{ nfs_allowed_network }}(rw,sync,no_subtree_check,no_root_squash)
{% endfor %}
```

`roles/nfs/handlers/main.yml` :

```yaml
---
- name: recharger les exports
  ansible.builtin.command: exportfs -ra
```

`group_vars/proxmox_nfs.yml` :

```yaml
---
nfs_device: /dev/sdb
nfs_root: /srv/nfs
nfs_allowed_network: "192.168.50.0/24"
nfs_exports:
  - images
  - iso
  - backup
  - snippets
```

🪤 **`no_root_squash`** : par défaut NFS transforme le `root` du client en `nobody`.
Proxmox a besoin d'écrire en root pour créer les disques de VM. On désactive donc le
squash — et **on restreint strictement l'export au réseau de management**. C'est un
compromis assumé : sur un vrai réseau, ce partage aurait son propre VLAN de stockage.

### Jouer le rôle

Ajoutez au `site.yml` :

```yaml
- name: Serveur NFS
  hosts: proxmox_nfs
  become: true
  roles:
    - common
    - nfs
```

```bash
cd ~/ProxmoxFormation/lab/ansible
rm -rf /tmp/ansible-pve-cache
ansible-inventory --graph | grep -A2 proxmox_nfs
ansible-playbook site.yml --limit proxmox_nfs
```

✅ Le tag `nfs` posé par Terraform a suffi à faire appliquer le rôle. **La chaîne
complète fonctionne.**

---

## 5. Vérifier depuis un nœud 🔬

```bash
apt install -y nfs-common
showmount -e 192.168.50.40
```

```
Export list for 192.168.50.40:
/srv/nfs/snippets 192.168.50.0/24
/srv/nfs/backup   192.168.50.0/24
/srv/nfs/iso      192.168.50.0/24
/srv/nfs/images   192.168.50.0/24
```

Test manuel avant de déclarer le stockage :

```bash
mkdir -p /mnt/test-nfs
mount -t nfs 192.168.50.40:/srv/nfs/images /mnt/test-nfs
touch /mnt/test-nfs/ok && ls -l /mnt/test-nfs && rm /mnt/test-nfs/ok
umount /mnt/test-nfs
```

🪤 Si `mount` échoue :
- pare-feu : NFSv4 n'a besoin que du **2049/tcp** — vérifiez `cluster.fw`,
- `rpcinfo -p 192.168.50.40`,
- `journalctl -u nfs-server` sur le serveur.

---

## 6. Déclarer le stockage dans Proxmox ⭐

**Chaque élève** le fait sur son nœud (au jour 4, une seule déclaration suffira pour
tout le cluster — c'est justement l'intérêt de pmxcfs).

🌐 `Datacenter → Storage → Add → NFS`

| Champ | Valeur |
|---|---|
| ID | `nfs-lab` |
| Server | `192.168.50.40` |
| Export | `/srv/nfs/images` (choisi dans la liste déroulante) |
| Content | `Disk image`, `Container`, `ISO image`, `Backup`, `Snippets` |
| Nodes | *toutes* (laisser vide) |
| Enable | ✅ |
| Options | `vers=4.2` |

```bash
pvesm add nfs nfs-lab \
  --server 192.168.50.40 \
  --export /srv/nfs/images \
  --content images,rootdir,iso,backup,snippets \
  --options vers=4.2 \
  --prune-backups 'keep-last=3'

pvesm status
cat /etc/pve/storage.cfg
df -h | grep nfs
mount | grep nfs
```

🧠 **`vers=4.2`** : NFSv4 n'utilise qu'un seul port (2049), simplifie énormément le
pare-feu, et gère mieux les verrous. NFSv3 nécessite `rpcbind`, `mountd`, `statd` sur
des ports variables — un cauchemar à filtrer. Forcez toujours la version 4.

---

## 7. L'utiliser 🚀

```bash
N=3
# Déplacer le disque d'une VM vers le NFS, à chaud
qm move-disk N20 scsi0 nfs-lab --delete 1
qm config N20 | grep scsi0
ls -l /mnt/pve/nfs-lab/images/N20/
```

```bash
# Une sauvegarde qui atterrit sur le NFS
vzdump N20 --storage nfs-lab --mode snapshot --compress zstd
ls -lh /mnt/pve/nfs-lab/dump/
```

🧠 Observez le format : sur un stockage `dir`/`nfs`, le disque est un **fichier
`.qcow2`** dans `images/<vmid>/`. Sur du LVM-thin, c'était un volume bloc. C'est cette
différence qui permet les snapshots qcow2 sur NFS — et qui explique la légère perte de
performance.

```bash
# Comparaison rapide des performances
qm stop N20 && qm start N20
ssh -J root@192.168.50.13 eleve@10.3.10.50 \
  'dd if=/dev/zero of=/tmp/t bs=1M count=512 oflag=direct; rm /tmp/t'
```

---

## 8. Ce qu'on vient de rendre possible 🔓

Avec un stockage partagé déclaré sur tous les nœuds :

| Fonction | Avant | Maintenant |
|---|---|---|
| Migration à chaud | copie du disque, plusieurs minutes | **quelques secondes** |
| Haute disponibilité | impossible | ✅ (TP 17) |
| Sauvegardes centralisées | une par nœud | un seul emplacement |
| ISO et templates | à dupliquer partout | ⭐ **partagés** |
| Snippets cloud-init | locaux | partagés → Terraform simplifié |

👉 On exploite tout ça au **TP 17**, une fois le cluster monté.

---

## ✅ Checklist de validation

- [ ] La VM `nfs-lab` existe, créée par Terraform, avec un disque `scsi1` de 60 Go
- [ ] Le tag `nfs` la place dans le groupe `proxmox_nfs` d'Ansible
- [ ] `ansible-playbook site.yml --limit proxmox_nfs` se termine sans erreur, et
      `changed=0` au second passage
- [ ] `showmount -e 192.168.50.40` liste les 4 exports depuis n'importe quel nœud
- [ ] Le stockage `nfs-lab` est actif dans `pvesm status`
- [ ] J'ai déplacé un disque de VM vers le NFS et la VM redémarre correctement
- [ ] Une sauvegarde `vzdump` atterrit dans `/mnt/pve/nfs-lab/dump/`
- [ ] Je sais expliquer pourquoi le NFS est sur `vmbr0` et pas sur un VNet SDN

---

## 🎁 Bonus

1. **Le disque plein** : remplissez l'export (`dd if=/dev/zero of=/mnt/pve/nfs-lab/big
   bs=1M count=60000`) et observez le comportement de Proxmox. Puis nettoyez.
   Ce genre d'incident arrive vraiment.
2. **Débrancher le NFS à chaud** : arrêtez la VM `nfs-lab` pendant qu'une VM tourne sur
   ce stockage. Observez le gel, les I/O en attente, les messages du noyau
   (`dmesg | grep nfs`). Redémarrez, et constatez la reprise. Comparez avec
   l'option de montage `soft` (à ne **pas** utiliser pour des disques de VM).
3. **CIFS/SMB** : ajoutez un second partage en SMB et comparez les performances
   (`fio` ou `dd`).
4. **Ceph** : si le formateur en fait la démonstration, comparez la philosophie —
   pas de SPOF, réplication à 3, mais 3 nœuds minimum et une exigence réseau bien
   supérieure.

➡️ Fin du jour 3 🎉 · Suite : [TP 15 — Mise en cluster des 6 nœuds](15-cluster-proxmox.md)
