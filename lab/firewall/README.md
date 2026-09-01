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

# 2. Datacenter — adapter les alias : le numéro d'élève ET les deux IP
#    qui ne sont pas connues d'avance (votre poste, la VM PBS)
PC=172.30.30.___          # ⚠ votre poste     : hostname -I
PBS=172.30.30.___         # ⚠ la VM PBS       : TP 15
sed -e "s/10\.3\./10.$N./g" \
    -e "s/^pc_eleve .*/pc_eleve $PC/" \
    -e "s/^srv_pbs .*/srv_pbs $PBS/" \
    cluster.fw.example > /etc/pve/firewall/cluster.fw

grep -E '^(pc_eleve|srv_pbs)' /etc/pve/firewall/cluster.fw   # ⭐ relire avant d'activer

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
#   … et en zone EVPN (TP 17), ajoutez --mtu 1450
```

## Les quatre pièges

1. **`nftables: 1` manquant** → les règles VNet sont ignorées, sans aucun message.
2. **Les alias `pc_eleve` et `srv_pbs` laissés tels quels** → ils portent des IP
   d'exemple. Une règle qui autorise la mauvaise adresse est pire qu'une règle
   absente : elle donne l'illusion du contrôle.
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
