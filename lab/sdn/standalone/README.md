# Configuration SDN — mode standalone (jour 2)

Ces fichiers reproduisent la configuration des TP 08 et 12. Aux jours 1-3, chaque
stagiaire est seul sur son nœud : la configuration est **identique pour tout le monde**,
rien à adapter.

## Utilisation

```bash
cp zones.cfg vnets.cfg subnets.cfg /etc/pve/sdn/

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
