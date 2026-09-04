# Configuration SDN — cluster EVPN (jour 4)

Configuration de référence du TP 17. **Cluster-wide** : à poser une seule fois,
depuis n'importe quel nœud.

## Prérequis, sur les 6 nœuds

```bash
apt install -y frr frr-pythontools
sysctl -w net.ipv4.ip_forward=1
```

Et dans `/etc/pve/firewall/cluster.fw`, section `[RULES]` :

```ini
IN ACCEPT -source lan_salle -p udp -dport 4789 -log nolog  # VXLAN
IN ACCEPT -source lan_salle -p tcp -dport 179  -log nolog  # BGP
```

`lab/firewall/cluster.fw.example` les contient déjà, ainsi que les règles
`FORWARD ACCEPT -source lan_salle -dest net_evpn …` (SSH, HTTP, PostgreSQL, ICMP) qui
permettent au poste de joindre les VM EVPN directement, via la route
`10.60.0.0/16 → 172.30.30.151` (TP 17 §8.2).

## Poser la configuration

```bash
cp controllers.cfg zones.cfg vnets.cfg subnets.cfg /etc/pve/sdn/
pvesh set /cluster/sdn
sleep 20
```

## Vérifier

```bash
bash ../../scripts/evpn-diag.sh
vtysh -c "show bgp l2vpn evpn summary"     # 5 voisins Established
ip -br a show vprod                        # même IP + même MAC sur tous les nœuds
```

## Adresses

| VNet | VNI | Subnet | Gateway | SNAT |
|---|---|---|---|---|
| `vprod` | 11010 | 10.60.10.0/24 | .1 | ✅ |
| `vpub`  | 11020 | 10.60.20.0/24 | .1 | ✅ |
| `vdb`   | 11030 | 10.60.30.0/24 | .1 | ❌ |

VRF de la zone : VNI **10000**. MTU : **1450**.

## Le rappel qui évite deux heures de perdues

Sur chaque carte réseau de VM branchée sur un de ces VNets :

```bash
qm set <vmid> --net0 virtio,bridge=vprod,firewall=1,mtu=1
#                                                  ^^^^^
#                              « hérite du MTU du bridge » → 1450
```

Sans ça : le ping passe, SSH gèle, `apt update` reste bloqué à 0 %.
