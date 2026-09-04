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
# 1. nftables — SANS LUI, LES RÈGLES VNET SONT IGNORÉES
apt install -y proxmox-firewall
cp host.fw.example /etc/pve/nodes/$(hostname)/host.fw

# 2. Datacenter — le fichier est directement utilisable : aucune adresse à adapter
cp cluster.fw.example /etc/pve/firewall/cluster.fw

# 3. VNets (vsrv.fw seulement à partir du TP 12 : c'est Terraform qui le pose)
mkdir -p /etc/pve/sdn/firewall
for v in vint vdmz; do cp "$v.fw.example" "/etc/pve/sdn/firewall/$v.fw"; done
# Avant le TP 12, le VNet vsrv n'existe pas : on neutralise les lignes qui le citent
sed -i '/+sdn\/vsrv-all/s/^/#/' /etc/pve/sdn/firewall/{vint,vdmz}.fw

# 4. Appliquer et redémarrer les guests
pvesh set /cluster/sdn
systemctl restart proxmox-firewall
```

## Vérifier

```bash
pve-firewall compile | head -30
nft list ruleset | grep -c .
tail -f /var/log/pve-firewall.log
bash ../scripts/test-firewall.sh --int 10.10.10.101 --dmz 10.10.20.101
#   … et en zone EVPN (TP 17), ajoutez --mtu 1450

# Depuis le PC : les règles FORWARD « lan_salle → net_* » laissent passer SSH, HTTP,
# PostgreSQL et ICMP vers toutes les VM des réseaux privés (route du TP 07)
ssh eleve@10.10.10.50 hostname
```

## La même chose en Terraform

À partir du TP 12, `cluster.fw` est **géré par Terraform** :
`lab/terraform/03-sdn-troisieme-lan/cluster-fw.tf` porte les mêmes options, alias,
IPSet, groupes et règles, en ressources natives du provider. Le fichier d'exemple
ci-dessus reste la référence lisible — et ce qu'on repose à la main si l'on détruit la
stack.

## Les quatre pièges

1. **`nftables: 1` manquant** → les règles VNet sont ignorées, sans aucun message.
2. **Un alias qui ne correspond plus à la réalité** (un réseau renuméroté, une IP
   d'exemple laissée telle quelle) → une règle qui autorise la mauvaise adresse est
   pire qu'une règle absente : elle donne l'illusion du contrôle. Relisez `[ALIASES]`.
3. **L'ordre des règles** → première correspondance gagnante. Une règle
   « ACCEPT vers Internet » sans `-dest` attrape tout, y compris les flux
   inter-zones. Les DROP explicites doivent la précéder.
4. **La règle Corosync (5405-5412)** → l'oublier casse le cluster à la seconde où
   vous activez le firewall.

## Désactivation d'urgence

```bash
pve-firewall stop
systemctl stop proxmox-firewall
```
