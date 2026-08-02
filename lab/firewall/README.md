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
N=3   # votre numéro d'élève

# 1. nftables — SANS LUI, LES RÈGLES VNET SONT IGNORÉES
apt install -y proxmox-firewall
cp host.fw.example /etc/pve/nodes/$(hostname)/host.fw

# 2. Datacenter (adapter les alias au numéro d'élève)
sed "s/10\.3\./10.$N./g" cluster.fw.example > /etc/pve/firewall/cluster.fw

# 3. VNets
mkdir -p /etc/pve/sdn/firewall
for v in vint vdmz vsrv; do
  [ -f "$v.fw.example" ] && cp "$v.fw.example" "/etc/pve/sdn/firewall/$v.fw"
done

# 4. Appliquer et redémarrer les guests
pvesh set /cluster/sdn
systemctl restart proxmox-firewall
```

## Vérifier

```bash
pve-firewall compile | head -30
nft list ruleset | grep -c .
tail -f /var/log/pve-firewall.log
bash ../scripts/test-firewall.sh --eleve 3 --int 10.3.10.101 --dmz 10.3.20.101
```

## Les trois pièges

1. **`nftables: 1` manquant** → les règles VNet sont ignorées, sans aucun message.
2. **L'ordre des règles** → première correspondance gagnante. Une règle
   « ACCEPT vers Internet » sans `-dest` attrape tout, y compris les flux
   inter-zones. Les DROP explicites doivent la précéder.
3. **La règle Corosync (5405-5412)** → l'oublier casse le cluster à la seconde où
   vous activez le firewall.

## Désactivation d'urgence

```bash
pve-firewall stop
systemctl stop proxmox-firewall
```
