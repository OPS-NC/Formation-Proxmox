# Annexe B — Dépannage 🔧

Les pannes que vous **allez** rencontrer, dans l'ordre de probabilité.

---

## 🧭 La méthode, avant les recettes

```
   ① QU'EST-CE QUI A CHANGÉ ?
      → 90 % des pannes suivent une modification. Laquelle ?

   ② LIRE LE MESSAGE D'ERREUR EN ENTIER
      → Datacenter → Tasks → double-clic sur la tâche rouge
      → journalctl -u <service> -n 50

   ③ ISOLER LA COUCHE
      Physique → L2 → L3 → transport → application
      ping IP, puis ping nom, puis nc -zv port, puis curl

   ④ COMPARER À CE QUI MARCHE
      Un autre nœud, une autre VM. Qu'est-ce qui diffère ?

   ⑤ UNE SEULE MODIFICATION À LA FOIS
      Sinon vous ne saurez jamais ce qui a résolu le problème.
```

---

## 🖥️ Installation et nœud

### L'interface web ne répond pas

```bash
systemctl status pveproxy pvedaemon
systemctl restart pveproxy
ss -tlnp | grep 8006
journalctl -u pveproxy -n 50 --no-pager
df -h /                                # 🪤 disque plein = tout casse
pve-firewall status                    # règle trop stricte ?
```

### `apt update` renvoie 401

Dépôt *enterprise* actif sans abonnement. Voir [TP 01 §5](../01-installation-proxmox.md).

### `hostname --ip-address` renvoie `127.0.1.1`

`/etc/hosts` mal renseigné. **À corriger avant toute mise en cluster.**

```
192.168.50.13   pve3.lab.local pve3
```

### Une VM refuse de démarrer : « KVM virtualisation not available »

VT-x / AMD-V désactivé dans le BIOS.

```bash
grep -Ec '(vmx|svm)' /proc/cpuinfo      # doit être > 0
```

---

## 💾 Stockage

### « no such volume »

```bash
pvesm status
lvs
cat /etc/pve/qemu-server/<vmid>.conf
```

Le stockage est désactivé, ou le volume a été supprimé hors de Proxmox.

### Un stockage `dir`/NFS est actif mais vide

```bash
mount | grep <chemin>
ls -la /mnt/pve/<storage>/
```

Montage tombé. Proxmox écrit alors **dans le répertoire local** sous le point de
montage. Démontez, videz, remontez.

### LVM-thin plein → VM en lecture seule

```bash
lvs -o +data_percent,metadata_percent
```

🚨 Au-delà de 95 %, les VM se corrompent. Étendez le pool ou supprimez des snapshots
**immédiatement**. Surveillez ce chiffre : c'est la panne n°1 en production.

### `lvreduce` refuse de réduire le thin pool 🪤

```
Thin pool volumes pve/data_tdata cannot be reduced in size yet.
```

**Ce n'est pas contournable proprement.** LVM ne sait pas réduire un thin pool : les
blocs ne sont pas alloués linéairement, et dm-thin n'offre aucun mécanisme de
défragmentation. La seule voie :

```bash
# 1. sauvegarder vers PBS et VÉRIFIER   2. détruire les guests
# 3. lvremove -y pve/data               4. lvcreate --type thin-pool -n data -L <plus petit> pve
# 5. lvcreate -n ceph-osd -L <reste> pve  6. restaurer
bash lab/scripts/ceph-prep-lvm.sh --check     # le script vous guide
```

👉 Détails complets : [TP 18 §5](../18-ceph-cluster.md).

### Le VG est plein et je n'ai plus de place pour Ceph

```bash
vgs -o vg_name,vg_size,vg_free --units g
lsblk        # y a-t-il un second disque libre ? → pveceph osd create /dev/sdb
```

Anticipez à l'installation : réduire `maxvz` laisse de l'espace non alloué
([TP 01 §3.1](../01-installation-proxmox.md)).

### Le disque ne rétrécit pas après suppression

```bash
qm set <vmid> --scsi0 <storage>:vm-X-disk-0,discard=on,ssd=1
# dans la VM :
fstrim -av
```

### NFS : `mount` échoue depuis le nœud

| Erreur | Piste |
|---|---|
| `Connection refused` | `systemctl status nfs-server` sur le poste Ubuntu |
| `access denied by server` | l'IP du nœud n'est pas dans `/etc/exports.d/*` |
| `No route to host` | `ufw` sur le poste, ou `cluster.fw` sur le nœud |
| `Permission denied` en écriture | `no_root_squash` absent, ou droits sur `/srv/nfs-eN` |
| `Protocol not supported` | v3 désactivée : forcez `-o vers=4.2` |

```bash
# côté poste Ubuntu
sudo exportfs -v ; ss -tlnp | grep 2049 ; sudo journalctl -u nfs-server -n 30
```

### Le stockage NFS est signalé en erreur sur les autres nœuds

L'export n'autorise qu'une IP. Restreignez la déclaration :

```bash
pvesm set nfs-e3 --nodes pve3
```

---

## 🌐 Réseau classique

### Une VM n'a pas de réseau

```bash
qm config <vmid> | grep net              # bon bridge ?
ip -br link | grep tap<vmid>             # l'interface tap existe ?
bridge link show | grep tap<vmid>        # rattachée au bon bridge ?
tcpdump -ni tap<vmid>i0 -c 20            # ça sort ?
tcpdump -ni vmbr0 -c 20                  # ça arrive sur le bridge ?
```

### `ifreload -a` ne change rien

```bash
ifquery --check --all
journalctl -u networking -n 30
```

Erreur de syntaxe dans `/etc/network/interfaces` : `ifupdown2` refuse et garde
l'ancienne configuration.

### Pas d'Internet depuis une VM en NAT

```bash
sysctl net.ipv4.ip_forward               # doit être à 1
iptables -t nat -L POSTROUTING -n -v     # la règle existe ? les compteurs montent ?
```

---

## 🕸️ SDN

### Le VNet n'apparaît pas dans `ip -br a`

**L'Apply a été oublié** — c'est la cause dans 8 cas sur 10.

```bash
diff /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg
pvesh set /cluster/sdn
```

### Pas d'IP en DHCP

```bash
systemctl is-active dnsmasq              # DOIT être « inactive »
systemctl status dnsmasq@<zone>
journalctl -u dnsmasq@<zone> -n 30
pvesh get /cluster/sdn/vnets/<vnet>/subnets   # dhcp-range défini ?
```

🪤 Un `dnsmasq` système actif occupe le port 67 et empêche les instances de zone
de démarrer.

### IP obtenue, mais pas d'Internet

- `snat` non coché sur le subnet,
- `policy_forward: DROP` sans règle VNet,
- en EVPN : pas d'exit node, ou pas de `exitnodes-primary`.

### « zone/vnet already exists » ou suppression impossible

Ordre imposé : **subnets → vnets → zones**.

```bash
pvesh delete /cluster/sdn/vnets/<vnet>/subnets/<zone>-<subnet-avec-tirets>
pvesh delete /cluster/sdn/vnets/<vnet>
pvesh delete /cluster/sdn/zones/<zone>
pvesh set /cluster/sdn
```

Ou le script `lab/scripts/reset-sdn.sh`.

---

## 🔀 EVPN — les 5 pannes classiques

### ① Les sessions BGP ne montent pas

```bash
vtysh -c "show bgp l2vpn evpn summary"
```

État `Active` ou `Connect` :

```bash
dpkg -l | grep frr-pythontools           # 🪤 le grand oubli
systemctl status frr
grep -n 179 /etc/pve/firewall/cluster.fw
ping <ip-du-voisin>
cat /etc/pve/sdn/controllers.cfg         # les IP des peers sont-elles justes ?
```

### ② BGP OK, mais les VM ne se joignent pas

Le plan de contrôle marche, pas le plan de données. **UDP 4789 est bloqué.**

```bash
# sur le nœud A
tcpdump -ni vmbr0 udp port 4789
# sur le nœud B : ping depuis une VM
```

Ajoutez dans `cluster.fw` :

```ini
IN ACCEPT -source lan_salle -p udp -dport 4789 -log nolog
```

### ③ Ping OK, SSH gèle, `apt` bloqué → **MTU** 🎯

La panne la plus fréquente et la plus déroutante.

```bash
# depuis la VM
ping -M do -s 1422 -c2 9.9.9.9      # ✅ doit passer
ping -M do -s 1473 -c2 9.9.9.9      # ❌ doit échouer proprement
```

Correctifs :

```bash
pvesh set /cluster/sdn/zones/<zone> --mtu 1450
qm set <vmid> --net0 virtio,bridge=<vnet>,mtu=1,firewall=1
pvesh set /cluster/sdn
```

### ④ Internet fonctionne une fois sur deux

`exitnodes-primary` non défini → ECMP + SNAT stateful = paquets retour perdus.

```bash
grep -A8 'evpn:' /etc/pve/sdn/zones.cfg
pvesh set /cluster/sdn/zones/<zone> --exitnodes-primary pve1
pvesh set /cluster/sdn
```

### ⑤ Une VM silencieuse est injoignable

Elle n'a pas émis d'ARP, donc aucune route /32 n'a été apprise.

```bash
pvesh set /cluster/sdn/zones/<zone> --advertise-subnets 1
pvesh set /cluster/sdn
```

---

## 🛡️ Firewall

### Les règles VNet sont ignorées

`nftables` n'est pas actif. Le `pve-firewall` iptables **ignore silencieusement** les
règles VNet.

```bash
grep nftables /etc/pve/nodes/$(hostname)/host.fw
apt install -y proxmox-firewall
systemctl status proxmox-firewall
```

### Je me suis coupé l'accès à `:8006`

Console physique ou IPMI :

```bash
pve-firewall stop
systemctl stop proxmox-firewall
vim /etc/pve/firewall/cluster.fw
```

### Une règle « ne marche pas »

Une règle **précédente** a déjà décidé. Les règles sont évaluées **de haut en bas,
première correspondance gagnante**.

```bash
nft list ruleset | grep -B3 counter | head -40   # quelles règles matchent ?
tail -f /var/log/pve-firewall.log
```

Ajoutez temporairement `-log info` sur les règles suspectes.

### Le trafic retour est bloqué

Non : le suivi de connexion (conntrack) l'autorise automatiquement. **Une seule règle
par sens de connexion suffit.** Si ça ne marche pas, le problème est ailleurs.

---

## 🔗 Cluster

### `pvecm add` échoue

```bash
qm list ; pct list                       # doivent être VIDES
pveversion                               # même version sur tous les nœuds
ping <ip-du-membre>
timedatectl status                       # horloges synchronisées
hostname --ip-address                    # pas 127.x
```

### Quorum perdu, `/etc/pve` en lecture seule

```bash
pvecm status
corosync-quorumtool -s
systemctl status corosync
journalctl -u corosync -n 50
```

Rétablissez les nœuds manquants. **En dernier recours seulement** :

```bash
pvecm expected <n>       # 🚨 risque de split-brain
```

### Un nœud reste en « offline » dans l'interface

```bash
systemctl restart corosync pve-cluster
systemctl restart pvestatd pveproxy
journalctl -u pve-cluster -n 30
```

### Cluster instable, nœuds qui « clignotent »

Latence Corosync trop élevée. Vérifiez la charge réseau, l'horloge, et envisagez un
lien dédié.

```bash
corosync-cfgtool -s
journalctl -u corosync | grep -i -E 'token|retransmit'
```

---

## 🐙 Ceph

### L'interface ne propose aucun disque pour créer un OSD

C'est normal : elle ne liste que les **disques entiers non utilisés**. Un volume LVM
n'en est pas un. Passez en CLI :

```bash
pveceph osd create /dev/pve/ceph-osd
# ou, si pveceph refuse :
ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
ceph-volume lvm create --data pve/ceph-osd --bluestore
```

### `ceph-volume` : `unable to find keyring`

```bash
mkdir -p /var/lib/ceph/bootstrap-osd
ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
chown -R ceph:ceph /var/lib/ceph/bootstrap-osd
```

### `Device is in use` / restes d'un usage précédent

```bash
ceph-volume lvm zap /dev/pve/ceph-osd --destroy
wipefs -a /dev/pve/ceph-osd
```

### L'OSD est créé mais reste `down`

```bash
ceph-volume lvm list
ceph-volume lvm activate --all
systemctl status ceph-osd@<id>
journalctl -u ceph-osd@<id> -n 50 --no-pager
chown -R ceph:ceph /var/lib/ceph/osd/ceph-<id>
```

### `MON_CLOCK_SKEW`

Ceph est **très** sensible à la dérive d'horloge.

```bash
for i in 11 12 13 14 15 16; do ssh root@192.168.50.$i 'date -Is; timedatectl | grep synchro'; done
```

### `HEALTH_WARN` qui ne se résorbe pas

```bash
ceph health detail
ceph -w                        # suivre la reconstruction
ceph osd tree                  # un OSD down ?
ceph df                        # un OSD nearfull ?
```

### 🚨 `OSD_NEARFULL` / `OSD_FULL`

À **85 %** Ceph avertit, à **95 %** il **arrête toutes les écritures du cluster**.

```bash
ceph osd df                    # identifier l'OSD le plus rempli
ceph df
# Gagner du temps en urgence (à ne pas laisser en place) :
ceph osd set-nearfull-ratio 0.87
# La vraie solution : supprimer des données, ou ajouter un OSD
```

### Le cluster Proxmox devient instable quand Ceph reconstruit

C'est **LA** limite d'un réseau partagé. Bridez, tout de suite :

```bash
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 2
ceph config set osd osd_recovery_op_priority 1
ceph config set osd osd_recovery_sleep 0.1
ceph osd set noout             # pendant une intervention
```

En production : **un réseau dédié pour Ceph**, un autre pour Corosync. Ce n'est pas
négociable.

### Repartir de zéro

```bash
pveceph purge --crash --logs
ceph-volume lvm zap /dev/pve/ceph-osd --destroy
```

---

## 🚚 Migration et HA

| Erreur | Cause | Solution |
|---|---|---|
| « CPU model not compatible » | `cpu: host` | `qm set <id> --cpu x86-64-v2-AES` puis redémarrage |
| « storage not available on node » | stockage local | `--with-local-disks` ou stockage partagé |
| « bridge does not exist » | VNet absent sur la cible | vérifier la liste `nodes` de la zone |
| « can't migrate VM with local device » | passthrough PCI/USB | détacher le matériel |
| HA ne redémarre pas la VM | disque sur `local-lvm` | `qm move-disk <id> scsi0 vm-store --delete 1` |
| `pvesr` ne veut créer aucun job | la réplication exige **ZFS** | utilisez Ceph (TP 18) |
| VM bloquée en « locked » | tâche interrompue | `qm unlock <vmid>` |

---

## 💾 PBS

| Symptôme | Solution |
|---|---|
| « certificate verification failed » | Empreinte erronée : `proxmox-backup-manager cert info` |
| « permission denied » | ACL manquante sur le namespace |
| Datastore plein après un prune | Lancez le **garbage collection** — le prune ne libère rien |
| Sauvegarde très lente | Vérifiez le réseau et les I/O du datastore ; désactivez le chiffrement pour comparer |
| « unable to acquire lock » | Une autre sauvegarde tourne, ou un verrou orphelin |
| Restauration impossible : clé perdue | 🚨 irrécupérable. C'est pour ça qu'existe la *paper key* |

---

## 🤖 Terraform

| Erreur | Solution |
|---|---|
| `401 authentication failure` | Format : `user@realm!tokenid=secret` |
| `403 Permission check failed` | Ajoutez le privilège manquant au rôle |
| `unable to parse directory volume name` | Bloc `ssh` du provider absent ; testez `ssh root@<node>` |
| `VM already exists` | Respectez le plan de VMID |
| `bridge 'X' does not exist` | Ajoutez `depends_on` sur l'apply SDN |
| Ressource supprimée à la main | `terraform state rm <adresse>` |
| `timeout waiting for agent` | `qemu-guest-agent` absent du template |

```bash
export TF_LOG=DEBUG ; terraform apply 2>&1 | tee /tmp/tf.log ; unset TF_LOG
```

---

## 🎼 Ansible

| Erreur | Solution |
|---|---|
| `Invalid data from server` (inventaire) | `apt install python3-proxmoxer` |
| Le rôle `nfs` tente de partitionner un disque | mettez `nfs_manage_disk: false` (TP 14) |
| Aucun hôte dans l'inventaire | Vérifiez le token, `validate_certs: false`, et videz le cache |
| `ansible_host` absent | L'agent QEMU ne tourne pas dans la VM |
| `UNREACHABLE` | Le rebond SSH (`ProxyCommand`) n'est pas configuré |
| `changed` à chaque exécution | Une tâche non idempotente : ajoutez `creates:` ou `changed_when:` |
| `sudo: a password is required` | `become: true` + `NOPASSWD` dans sudoers, ou `--ask-become-pass` |

```bash
rm -rf /tmp/ansible-pve-cache
ansible-inventory --graph
ansible all -m ping -vvv
```

---

## 🚑 Les commandes de la dernière chance

```bash
# Firewall : je me suis enfermé dehors
pve-firewall stop ; systemctl stop proxmox-firewall

# Cluster : je dois travailler sans quorum (DANGER)
pvecm expected 1
# ou, pour remonter pmxcfs seul :
systemctl stop pve-cluster && pmxcfs -l

# Guest bloqué
qm unlock <vmid> ; pct unlock <ctid>
rm -f /var/lock/qemu-server/lock-<vmid>.conf

# Réseau : revenir en arrière
cp /etc/network/interfaces.bak /etc/network/interfaces && ifreload -a

# SDN : tout remettre à zéro
bash lab/scripts/reset-sdn.sh

# Tout redémarrer sans toucher aux VM
systemctl restart pvedaemon pveproxy pvestatd pve-cluster corosync
```

---

## 📞 Où chercher de l'aide

1. **La documentation locale** : bouton *Documentation* dans l'interface — hors ligne,
   toujours à jour avec votre version.
2. **Le log de la tâche** : `Datacenter → Tasks → double-clic`.
3. **`journalctl -u <service> -n 100 --no-pager`**.
4. **Le forum Proxmox** : <https://forum.proxmox.com/> — très actif, les développeurs
   y répondent.
5. **Le bug tracker** : <https://bugzilla.proxmox.com/>.
6. **La liste pve-devel** : <https://lore.proxmox.com/> — pour comprendre *pourquoi*
   une fonctionnalité est comme elle est.
