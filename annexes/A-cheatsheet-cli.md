# Annexe A — Cheatsheet CLI Proxmox 🗂️

Toutes les commandes utiles de la formation, classées. À imprimer.

---

## 🧭 Les outils, en un coup d'œil

| Commande | Domaine |
|---|---|
| `pveversion` | version |
| `pvesh` | **navigation dans l'API** — fait tout |
| `pvecm` | cluster |
| `pvesm` | stockages |
| `pveum` | utilisateurs, rôles, tokens |
| `pveam` | templates LXC |
| `qm` | machines virtuelles |
| `pct` | conteneurs LXC |
| `vzdump` | sauvegardes |
| `pve-firewall` | firewall historique (back-end iptables — ignore les règles VNet) |
| `proxmox-firewall` | firewall nftables (requis pour les règles VNet — `nftables: 1`) |
| `ha-manager` | haute disponibilité |
| `pvesr` | réplication |
| `vtysh` | FRRouting (BGP/EVPN) |
| `pveceph` | Ceph, côté Proxmox |
| `ceph` / `ceph-volume` | Ceph, côté natif |
| `lvs` / `vgs` / `lvcreate` | LVM — indispensable pour préparer un OSD |

---

## 🖥️ Système et nœud

```bash
pveversion -v                       # versions détaillées
pvesh get /nodes/$(hostname)/status --output-format yaml
pveperf                             # mini-benchmark
systemctl --failed
journalctl -u pveproxy -f
journalctl -u pvedaemon -n 50 --no-pager
hostname --ip-address               # DOIT être l'IP réelle, pas 127.x
timedatectl status
pvesh get /nodes/$(hostname)/tasks --limit 20     # historique des tâches
```

---

## 💾 Stockage

```bash
pvesm status
pvesm list <storage>
pvesm add <type> <id> [options]
pvesm set <id> --content images,rootdir,iso,vztmpl,backup,snippets
pvesm remove <id>
pvesm alloc <storage> <vmid> <name> <size>
pvesm free <storage>:<volume>
cat /etc/pve/storage.cfg

# NFS  (le serveur, c'est votre poste Ubuntu — TP 14)
PC=172.30.30.___   # l'IP de votre poste — hostname -I
pvesm add nfs nfs-pc --server $PC --export /srv/nfs \
    --content images,rootdir,iso,backup,snippets --options vers=4.2
#   en cluster (jour 4) : un ID unique et une restriction au nœud
#   pvesm add nfs nfs-$(hostname) ... --nodes $(hostname)
showmount -e <serveur>
mount -t nfs -o vers=4.2 <serveur>:/srv/nfs /mnt/test         # tester AVANT de déclarer

# Côté serveur NFS (poste Ubuntu)
sudo exportfs -v ; sudo exportfs -ra
cat /proc/fs/nfsd/versions
sudo journalctl -u nfs-server -n 30 --no-pager

# Ceph (déclaré automatiquement par « pveceph pool create --add_storages 1 »)
pvesm status | grep -E 'rbd|cephfs'

# PBS
pvesm add pbs pbs-lab --server <ip> --datastore <ds> --namespace <ns> \
    --username user@pbs --password '...' --fingerprint '...'

# LVM — ⭐ à connaître par cœur
pvs ; vgs ; lvs
lvs -o lv_name,vg_name,lv_size,pool_lv,data_percent,metadata_percent --units g
vgs -o vg_name,vg_size,vg_free --units g      # espace NON alloué → dispo pour Ceph
lvs -a -o +devices                            # y compris les LV cachés (_tdata, _tmeta)
lvcreate -n ceph-osd -L 60G pve               # un LV pour un OSD Ceph
lvremove -y pve/data                          # ⚠ détruit le thin pool
lvcreate --type thin-pool -n data -L 200G pve # le recrée plus petit
lvextend -L +50G pve/data                     # agrandir : autorisé
lvreduce -L -50G pve/data                     # 🪤 REFUSÉ sur un thin pool
```

> 🚨 **`data_percent` au-delà de 95 % → les VM se corrompent.** C'est la métrique à
> surveiller en premier sur un hyperviseur en LVM-thin.
>
> 🧠 **Pas de ZFS dans cette formation** : les nœuds sont en `ext4 + LVM-thin`.
> `zpool` / `zfs` ne sont donc pas utilisés.

---

## 🖥️ Machines virtuelles (`qm`)

```bash
qm list
qm config <vmid>
pvesh get /cluster/nextid                  # ⭐ le prochain VMID libre (jour 4 : toujours lui)
qm create <vmid> --name X --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm set <vmid> --memory 4096                # à chaud si hotplug actif
qm start|stop|shutdown|reboot|reset <vmid>
qm destroy <vmid> --purge
qm clone <src> <dst> --name X [--full 1]
qm template <vmid>
qm migrate <vmid> <node> --online [--with-local-disks]
qm resize <vmid> scsi0 +10G
qm move-disk <vmid> scsi0 <storage> --delete 1
qm importdisk <vmid> <fichier.qcow2> <storage>
qm set <vmid> --scsi0 <storage>:0,import-from=/chemin/image.qcow2

# Snapshots
qm snapshot <vmid> <nom> [--vmstate 1]
qm listsnapshot <vmid>
qm rollback <vmid> <nom>
qm delsnapshot <vmid> <nom>

# Console
qm terminal <vmid>                         # série — Ctrl+O pour sortir
qm monitor <vmid>                          # monitor QEMU
qm showcmd <vmid> --pretty                 # la ligne de commande QEMU générée

# Agent invité
qm agent <vmid> ping
qm agent <vmid> network-get-interfaces
qm guest cmd <vmid> get-osinfo
qm guest exec <vmid> -- /bin/ls /

# Cloud-init
qm set <vmid> --ide2 <storage>:cloudinit
qm set <vmid> --ciuser X --cipassword "$(openssl passwd -6 'mdp')"
qm set <vmid> --sshkeys /root/.ssh/authorized_keys
qm set <vmid> --ipconfig0 ip=10.10.10.50/24,gw=10.10.10.1
qm set <vmid> --ipconfig0 ip=dhcp
qm set <vmid> --cicustom "user=local:snippets/user.yaml"
qm cloudinit dump <vmid> user|network|meta
qm cloudinit update <vmid>

# Options utiles
qm set <vmid> --protection 1               # interdit la suppression
qm set <vmid> --onboot 1 --startup order=2,up=30
qm set <vmid> --hotplug disk,network,usb,memory,cpu
qm set <vmid> --tags "web,prod,debian"
```

---

## 📦 Conteneurs (`pct`)

```bash
pct list
pct config <ctid>
pct create <ctid> <template> --hostname X --rootfs local-lvm:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1
pct start|stop|shutdown|reboot <ctid>
pct destroy <ctid> --purge
pct enter <ctid>
pct exec <ctid> -- <commande>
pct push <ctid> <local> <distant>
pct pull <ctid> <distant> <local>
pct clone <src> <dst> --hostname X
pct template <ctid>
pct set <ctid> --memory 1024 --cores 2
pct set <ctid> -mp0 /srv/data,mp=/data          # bind mount
pct resize <ctid> rootfs +5G
pct fsck <ctid>

# Templates
pveam update
pveam available --section system
pveam download local <template>
pveam list local
```

---

## 🌐 Réseau et SDN

```bash
# Réseau classique
ip -br a ; ip -br link ; ip route
cat /etc/network/interfaces
ifreload -a                                 # applique sans reboot (ifupdown2)
bridge link show ; bridge fdb show
tcpdump -ni <interface> -c 20

# SDN — lecture
pvesh get /cluster/sdn/zones
pvesh get /cluster/sdn/vnets
pvesh get /cluster/sdn/vnets/<vnet>/subnets
pvesh get /cluster/sdn/controllers
pvesh get /cluster/sdn/ipam/pve/status
ls -l /etc/pve/sdn/
diff /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg

# SDN — écriture
pvesh create /cluster/sdn/zones --zone Z --type simple --ipam pve --dhcp dnsmasq   # --nodes <liste> pour restreindre (cluster)
pvesh create /cluster/sdn/vnets --vnet V --zone Z
pvesh create /cluster/sdn/vnets/V/subnets --subnet 10.0.0.0/24 --type subnet \
    --gateway 10.0.0.1 --snat 1 --dhcp-range start-address=10.0.0.100,end-address=10.0.0.200
pvesh set /cluster/sdn                      # ⭐ APPLY — ne l'oubliez jamais
pvesh delete /cluster/sdn/zones/<zone>

# SDN — généré
cat /etc/network/interfaces.d/sdn
cat /etc/frr/frr.conf
systemctl status dnsmasq@<zone>
```

---

## 🐙 Ceph

```bash
# Déploiement
pveceph install --repository no-subscription
pveceph init --network 172.30.30.0/24 --size 3 --min_size 2
pveceph mon create                      # sur 3 nœuds
pveceph mgr create                      # sur 2 nœuds
pveceph mds create                      # pour CephFS
pveceph osd create /dev/pve/ceph-osd    # ⭐ un LV : CLI obligatoire, l'UI ne le propose pas
pveceph osd destroy <id> --cleanup
pveceph pool create vm-store --size 3 --min_size 2 --pg_autoscale_mode on --add_storages 1
pveceph fs create --name cephfs --add-storage 1
pveceph status
pveceph purge --crash --logs            # ⚠ détruit tout

# Si pveceph refuse le volume logique
mkdir -p /var/lib/ceph/bootstrap-osd
ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
chown -R ceph:ceph /var/lib/ceph/bootstrap-osd
ceph-volume lvm create --data pve/ceph-osd --bluestore
ceph-volume lvm list
ceph-volume lvm activate --all
ceph-volume lvm zap /dev/pve/ceph-osd --destroy   # ⚠ effacer les traces

# État et diagnostic
ceph -s                        # ⭐ la commande à taper en premier
ceph health detail
ceph df                        # espace par pool
ceph osd df                    # remplissage par OSD
ceph osd tree                  # la hiérarchie CRUSH
ceph osd perf                  # latences
ceph -w                        # journal en direct
ceph versions

# OSD
ceph osd out <id> ; ceph osd in <id>
ceph osd set noout             # suspendre la reconstruction (maintenance)
ceph osd unset noout

# Brider la reconstruction — ⭐ obligatoire sur réseau partagé
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 2
ceph config set osd osd_recovery_op_priority 1
ceph config set osd osd_recovery_sleep 0.1
ceph config dump | grep -E 'backfill|recovery'

# Pools et images
ceph osd pool ls detail
ceph osd map vm-store vm-<vmid>-disk-0  # sur QUELS OSD est cet objet ?
rbd -p vm-store ls -l
rbd -p vm-store du
rbd -p vm-store info vm-<vmid>-disk-0

# CephFS
ceph fs status
df -h /mnt/pve/cephfs

# Benchmark
rados bench -p vm-store 30 write --no-cleanup
rados bench -p vm-store 30 rand
rados -p vm-store cleanup
```

---

## 🔀 EVPN / BGP (`vtysh`)

```bash
vtysh -c "show bgp l2vpn evpn summary"      # ⭐ les sessions BGP
vtysh -c "show bgp l2vpn evpn route"
vtysh -c "show bgp l2vpn evpn route type prefix"    # routes type-5
vtysh -c "show bgp l2vpn evpn route type macip"     # routes type-2
vtysh -c "show evpn vni detail"
vtysh -c "show evpn mac vni all"
vtysh -c "show evpn arp-cache vni all"
vtysh -c "show vrf"
vtysh -c "show ip route vrf vrf_<zone>"
vtysh -c "show running-config"

ip -d link show type vxlan
bridge fdb show | grep vxlan
ip route show vrf vrf_<zone>
tcpdump -ni vmbr0 udp port 4789 -c 20
```

---

## 🛡️ Firewall

```bash
pve-firewall status
pve-firewall compile                        # voir les règles générées
pve-firewall stop                           # 🚨 urgence
systemctl status proxmox-firewall
nft list tables                       # les tables : « ip nat » ET « inet proxmox-firewall »
nft list table ip nat                 # le SNAT du SDN (écrit via iptables-nft)
nft list table inet proxmox-firewall  # le firewall — table SÉPARÉE, elles ne se voient pas
iptables -V                           # → (nf_tables) : iptables = front-end de nftables

# Fichiers
/etc/pve/firewall/cluster.fw
/etc/pve/nodes/<node>/host.fw
/etc/pve/firewall/<vmid>.fw
/etc/pve/sdn/firewall/<vnet>.fw

# Objets
pvesh create /cluster/firewall/aliases --name X --cidr 10.0.0.0/24
pvesh create /cluster/firewall/ipset --name X
pvesh create /cluster/firewall/ipset/X --cidr 10.0.0.1
pvesh create /cluster/firewall/groups --group X
pvesh get /cluster/firewall/rules

# Journaux
tail -f /var/log/pve-firewall.log
journalctl -f -u proxmox-firewall
```

**IPSets SDN générés automatiquement**
`+sdn/<vnet>-all` · `+sdn/<vnet>-gateway` · `+sdn/<vnet>-no-gateway` · `+sdn/<zone>-all`

---

## 🔗 Cluster

```bash
pvecm create <nom> --link0 <ip>
pvecm add <ip-d-un-membre> --link0 <mon-ip>
pvecm status
pvecm nodes
pvecm delnode <node>
pvecm expected <n>                          # 🚨 forçage de quorum
pvecm qdevice setup <ip>

corosync-quorumtool -s
corosync-cfgtool -s
journalctl -u corosync -n 50 --no-pager
cat /etc/pve/corosync.conf
cat /etc/pve/.members
```

---

## 🏥 Haute disponibilité et réplication

> `pvesr` (réplication de stockage) **exige ZFS** : inutilisable dans cette formation.
> Le stockage partagé, c'est Ceph (TP 18).

```bash
ha-manager status [--verbose]
ha-manager add vm:<vmid> --group <grp> --state started
ha-manager remove vm:<vmid>
ha-manager migrate vm:<vmid> <node>
ha-manager crm-command node-maintenance enable <node>

pvesh create /cluster/ha/groups --group X --nodes "pve1:100,pve2:50"
pvesh get /cluster/ha/resources

pvesr status
pvesr run --id <jobid> --verbose
pvesh create /nodes/<node>/replication --id <vmid>-0 --target <node2> --schedule '*/15'
```

---

## 💾 Sauvegarde

```bash
vzdump <vmid> --storage <st> --mode snapshot --compress zstd
vzdump --all --storage <st> --mode snapshot
vzdump <vmid> --storage <st> --notes-template '{{guestname}} — {{node}}'

qm restore <newid> <storage>:backup/vm/<vmid>/<timestamp> --storage local-lvm
pct restore <newid> /chemin/vzdump-lxc-*.tar.zst --storage local-lvm

# PBS, côté serveur
proxmox-backup-manager datastore list
proxmox-backup-manager namespace list --store <ds>
proxmox-backup-manager garbage-collection start <ds>
proxmox-backup-manager prune-job list
proxmox-backup-manager verify-job create <id> --store <ds> --schedule 'sat 03:00'
proxmox-backup-manager cert info | grep -i fingerprint
proxmox-backup-manager user list
proxmox-backup-manager acl list

# PBS, côté client
export PBS_REPOSITORY='user@pbs@<ip>:<datastore>'
proxmox-backup-client snapshot list --ns <ns>
proxmox-backup-client backup etc.pxar:/etc
proxmox-backup-client restore <snapshot> <archive> <destination>
proxmox-backup-client key create <fichier>
proxmox-backup-client key paperkey <fichier>
```

---

## 🔐 Utilisateurs, rôles, tokens

```bash
pveum user list|add|modify|delete
pveum group add <grp>
pveum role list
pveum role add <role> -privs "VM.Audit Sys.Audit"
pveum acl list
pveum aclmod <chemin> --users X --roles Y
pveum aclmod /pool/<pool> --groups <grp> --roles PVEVMUser
pveum user token add <user> <tokenid> --privsep 0
pveum user token list <user>
pveum user token remove <user> <tokenid>

# Test d'un token
curl -sk -H "Authorization: PVEAPIToken=user@pve!id=SECRET" \
     https://<node>:8006/api2/json/nodes | jq
```

---

## 📁 Pools et tags

```bash
pvesh create /pools --poolid <nom>
pvesh get /pools
pvesh set /pools/<nom> --vms <vmid>
qm set <vmid> --tags "a,b,c"
pct set <ctid> --tags "a,b,c"

pvesh get /cluster/resources --type vm --output-format json \
  | jq -r '.[] | "\(.vmid)\t\(.name)\t\(.tags // "-")"'
```

---

## 🌍 API

```bash
pvesh ls /
pvesh ls /nodes
pvesh get <chemin> [--output-format json|yaml|table]
pvesh create|set|delete <chemin> [--param valeur]
pvesh usage /cluster/sdn/zones -v          # ⭐ l'aide en ligne d'un endpoint

# En HTTP
TOKEN='user@pve!id=SECRET'
curl -sk -H "Authorization: PVEAPIToken=$TOKEN" https://node:8006/api2/json/cluster/resources | jq
```

---

## 🔧 Fichiers importants

| Chemin | Contenu |
|---|---|
| `/etc/pve/` | **pmxcfs** — répliqué sur tout le cluster |
| `/etc/pve/qemu-server/<vmid>.conf` | configuration d'une VM |
| `/etc/pve/lxc/<ctid>.conf` | configuration d'un CT |
| `/etc/pve/storage.cfg` | stockages |
| `/etc/pve/datacenter.cfg` | options du datacenter |
| `/etc/pve/corosync.conf` | cluster |
| `/etc/pve/user.cfg` | utilisateurs et ACL |
| `/etc/pve/sdn/*.cfg` | SDN (`.running.cfg` = appliqué) |
| `/etc/pve/firewall/` | firewall cluster et guests |
| `/etc/pve/nodes/<n>/host.fw` | firewall du nœud |
| `/etc/network/interfaces` | réseau (partie manuelle) |
| `/etc/network/interfaces.d/sdn` | réseau **généré** par le SDN |
| `/etc/frr/frr.conf` | BGP/EVPN, **généré** |
| `/var/lib/vz/` | stockage `local` |
| `/mnt/pve/<storage>/` | points de montage NFS / CIFS / CephFS |
| `/etc/pve/ceph.conf` | configuration Ceph (cluster-wide) |
| `/etc/ceph/ceph.conf` | lien symbolique vers le précédent |
| `/etc/pve/priv/ceph.*` | clés Ceph |
| `/var/lib/ceph/osd/ceph-<id>/` | métadonnées d'un OSD |
| `/etc/exports.d/*.exports` | exports NFS (sur le poste Ubuntu) |

---

## 🚑 Commandes d'urgence

```bash
pve-firewall stop                          # je me suis coupé l'accès
systemctl stop proxmox-firewall
pvecm expected 1                           # 🚨 forcer le quorum (danger)
qm unlock <vmid>                           # VM bloquée en « locked »
pct unlock <ctid>
rm /var/lock/qemu-server/lock-<vmid>.conf
systemctl restart pveproxy pvedaemon pvestatd
systemctl restart pve-cluster              # remonter pmxcfs
pmxcfs -l                                  # 🚨 pmxcfs en mode local (hors quorum)

# Ceph bloqué / cluster saturé
ceph osd set noout                         # geler la reconstruction
ceph config set osd osd_recovery_sleep 0.5 # ralentir encore
```
