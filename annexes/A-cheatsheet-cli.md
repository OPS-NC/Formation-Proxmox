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
| `pve-firewall` | firewall (iptables) |
| `ha-manager` | haute disponibilité |
| `pvesr` | réplication |
| `vtysh` | FRRouting (BGP/EVPN) |

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

# NFS
pvesm add nfs nfs-lab --server 192.168.50.40 --export /srv/nfs/images \
    --content images,backup --options vers=4.2
showmount -e <serveur>

# PBS
pvesm add pbs pbs-lab --server <ip> --datastore <ds> --namespace <ns> \
    --username user@pbs --password '...' --fingerprint '...'

# LVM / ZFS
vgs ; lvs ; pvs
zpool status ; zfs list ; zfs get compressratio
```

---

## 🖥️ Machines virtuelles (`qm`)

```bash
qm list
qm config <vmid>
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
qm set <vmid> --ipconfig0 ip=10.3.10.50/24,gw=10.3.10.1
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
pvesh create /cluster/sdn/zones --zone Z --type simple --nodes pveN --ipam pve --dhcp dnsmasq
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
nft list tables ; nft list ruleset | head -50

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
| `/mnt/pve/<storage>/` | points de montage NFS/CIFS |

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
```
