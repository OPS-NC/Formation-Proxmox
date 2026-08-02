# Configuration SDN — mode standalone (jour 2)

Ces fichiers reproduisent la configuration des TP 08 et 12 pour **l'élève 3**.

## Utilisation

⚠️ **Ne les copiez pas aveuglément** : adaptez le nom du nœud (`pve3`) et le numéro
d'élève (`10.3.x.x`) au vôtre.

```bash
N=3        # votre numéro
NODE=pve3  # votre nœud

for f in zones vnets subnets; do
  sed -e "s/pve3/$NODE/g" -e "s/10\.3\./10.$N./g" -e "s/e3$/e$N/" \
      $f.cfg > /etc/pve/sdn/$f.cfg
done

pvesh set /cluster/sdn          # ⭐ l'apply, sans lui rien ne se passe
ip -br a | grep -E 'vint|vdmz|vsrv'
```

## Vérifier

```bash
diff /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg && echo "synchronisé"
systemctl status dnsmasq@zint --no-pager | head -3
pvesh get /cluster/sdn/ipam/pve/status
```

## Repartir de zéro

```bash
bash ../../scripts/reset-sdn.sh
```
