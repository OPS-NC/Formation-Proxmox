# Fichiers firewall d'exemple

## Où va quoi

| Fichier d'exemple | Destination |
|---|---|
| `cluster.fw.example` | `/etc/pve/firewall/cluster.fw` |
| `host.fw.example` | `/etc/pve/nodes/<nodename>/host.fw` |
| `vint.fw.example` | `/etc/pve/sdn/firewall/vint.fw` |
| `vdmz.fw.example` | `/etc/pve/sdn/firewall/vdmz.fw` |
| `vsrv.fw.example` | `/etc/pve/sdn/firewall/vsrv.fw` |

## Mise en place

```bash
# 0. Le back-end iptables DOIT être nft, pas legacy
#    Sinon le SNAT du SDN part dans les tables legacy, invisible depuis
#    « nft list ruleset », et le NAT du TCP cesse de fonctionner.
iptables -V                                    # → (nf_tables), PAS (legacy)
update-alternatives --set iptables  /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft

# 1. nftables — SANS LUI, LES RÈGLES VNET SONT IGNORÉES
apt install -y proxmox-firewall
cp host.fw.example /etc/pve/nodes/$(hostname)/host.fw

# 2. Datacenter — le fichier est directement utilisable : aucune adresse à adapter
cp cluster.fw.example /etc/pve/firewall/cluster.fw

# 3. VNets — ne copiez que ceux qui existent. vsrv n'arrive qu'au TP 12, posé par
#    Terraform. Une règle qui cite un IPSet inconnu (+sdn/vsrv-all) est ignorée en
#    silence par proxmox-firewall : on neutralise ces lignes jusqu'au TP 12.
mkdir -p /etc/pve/sdn/firewall
for v in vint vdmz; do cp "$v.fw.example" "/etc/pve/sdn/firewall/$v.fw"; done
sed -i '/+sdn\/vsrv-all/s/^/#/' /etc/pve/sdn/firewall/{vint,vdmz}.fw

# 4. Appliquer et redémarrer les guests
#    ⭐ Le redémarrage n'est PAS cosmétique : tant qu'un guest tourne derrière son
#    bridge fwbrXXXiY (topologie de l'ancien pve-firewall), sa zone conntrack
#    diverge et le SNAT ne traduit plus le TCP. Ping et DNS passent, curl non.
pvesh set /cluster/sdn
systemctl restart proxmox-firewall
for id in $(qm list | awk 'NR>1{print $1}'); do qm reboot $id; done
for id in $(pct list | awk 'NR>1{print $1}'); do pct reboot $id; done
```

## Vérifier

```bash
pve-firewall compile | head -30
nft list ruleset | grep -c .
tail -f /var/log/pve-firewall.log

# ⭐ Les trois contrôles qui évitent la plupart des « ça ne marche pas »
iptables -V                                                     # → (nf_tables)
ip -br link | grep fwbr                                         # → doit être VIDE
journalctl -u proxmox-firewall -n 50 | grep "could not find ipset"   # → VIDE

# Où meurt exactement un paquet ? (remplacez l'IP source)
nft add table inet dbg
nft add chain inet dbg pre '{ type filter hook prerouting priority -300; }'
nft add rule  inet dbg pre ip saddr 10.10.20.101 meta nftrace set 1
nft monitor trace          # … puis générez le trafic depuis la VM
nft delete table inet dbg  # ⚠ ne pas oublier
bash ../scripts/test-firewall.sh --int 10.10.10.101 --dmz 10.10.20.101
#   … et en zone EVPN (TP 17), ajoutez --mtu 1450

# Depuis le PC : les règles FORWARD « lan_salle → net_* » laissent passer SSH, HTTP,
# PostgreSQL et ICMP vers toutes les VM des réseaux privés (route du TP 07)
ssh eleve@10.10.10.50 hostname
```

## La même chose en Terraform

À partir du TP 12, `cluster.fw` est **géré par Terraform** :
`lab/terraform/03-sdn-troisieme-lan/cluster-fw.tf` porte les mêmes options, alias,
IPSet, groupes et règles, en ressources natives. Le fichier d'exemple reste la référence
lisible, et ce qu'on repose à la main après un `destroy`.

## Les six pièges

1. **Croire que les `.fw` de VNet suffisent** → ils ne filtrent que l'**intra-VNet**
   et le **VNet ↔ hôte**. Tout ce qui sort d'un VNet (autre VNet, Internet, et le
   trafic venu du poste) est **routé** par l'hôte et n'est filtré que par les règles
   `FORWARD` de `cluster.fw` / `host.fw`. Avec `policy_forward: DROP` et aucune règle
   `FORWARD` au Datacenter, plus rien ne sort, quoi que disent les fichiers de VNet.
   Voir TP 09 §5.4.
2. **`nftables: 1` manquant** → les règles VNet sont ignorées, sans message.
   Et **`nftables: 1` sans redémarrer les guests** → ils restent derrière leurs
   bridges `fwbr*`, la zone conntrack diverge, et le **SNAT ne traduit plus le
   TCP** (`ping` et DNS passent, `curl` non).
3. **Le back-end `iptables`** → s'il pointe sur `iptables-legacy`, le SNAT du SDN
   est écrit dans des tables invisibles depuis `nft list ruleset`. Diagnostic
   classique et faux : « le NAT a disparu ».
4. **Le DHCP oublié** → dès qu'un VNet passe en `policy_forward: DROP`, le
   `DHCPDISCOVER` (source `0.0.0.0`) et l'`OFFER` tombent sur le `drop` final.
   La panne est **différée** : elle n'apparaît qu'au redémarrage suivant du guest.
5. **Une règle qui référence un IPSet inexistant** (`+sdn/vsrv-all` avant le
   TP 12) → `proxmox-firewall` la **saute silencieusement**. Rien à l'écran :
   `journalctl -u proxmox-firewall | grep "could not find ipset"`.
6. **Un alias qui ne correspond plus à la réalité** (réseau renuméroté, IP d'exemple
   laissée telle quelle) → une règle qui autorise la mauvaise adresse est pire qu'une
   règle absente. Relisez `[ALIASES]`.

Et les deux classiques :

- **L'ordre des règles** → première correspondance gagnante. Une règle
  « ACCEPT vers Internet » sans `-dest` attrape tout, y compris les flux
  inter-zones. Les DROP explicites doivent la précéder.
- **La règle Corosync (5405-5412)** → l'oublier casse le cluster à la seconde où
  vous activez le firewall.

## Désactivation d'urgence

```bash
pve-firewall stop
systemctl stop proxmox-firewall
```
