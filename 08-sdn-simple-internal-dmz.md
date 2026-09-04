# TP 08 — SDN : les zones `internal` et `dmz` 🌐

⏱️ **2 h** · Jour 2

Objectif : refaire le TP 07, en mieux — deux réseaux segmentés, avec IPAM, DHCP et NAT
vers Internet, **sans écrire une seule règle iptables ni éditer `/etc/network/interfaces`**.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html>
📖 Référence maison : [`SDN.md`](SDN.md) — lisez au moins les §1, §2.1 et §5-6

---

## 1. La cible 🎯

```
                              ☁ Internet
                                   │
                          172.30.30.2
                                   │
   ══════════════ LAN salle 172.30.30.0/24 ══════════════
                                   │
                              ┌────┴────┐
                              │  vmbr0  │
                              └────┬────┘
                                   │
                          ╔════════╧════════╗
                          ║   NŒUD pve      ║
                          ║   SNAT ×2       ║
                          ╚═══╤═════════╤═══╝
                    zone zint │         │ zone zdmz
                      vnet    │         │   vnet
                     ┌────────┴──┐   ┌──┴─────────┐
                     │   vint    │   │    vdmz    │
                     │ 10.10.10.0│   │ 10.10.20.0 │
                     │  /24      │   │   /24      │
                     │ gw .1     │   │  gw .1     │
                     │ DHCP      │   │  DHCP      │
                     └──┬─────┬──┘   └──┬──────┬──┘
                        │     │         │      │
                     ┌──┴─┐ ┌─┴──┐   ┌──┴─┐ ┌──┴──┐
                     │srv1│ │win1│   │alpi│ │rocky│
                     └────┘ └────┘   └────┘ └─────┘
                     Debian Windows  Alpine  Rocky
                      (VM)   (VM)    (LXC)   (LXC)
```

| VNet | Zone | Subnet | Gateway | DHCP | SNAT | Rôle |
|---|---|---|---|---|---|---|
| `vint` | `zint` | `10.10.10.0/24` | `10.10.10.1` | `.100-.200` | ✅ | Back-office, bases |
| `vdmz` | `zdmz` | `10.10.20.0/24` | `10.10.20.1` | `.100-.200` | ✅ | Services exposés |

🧠 Ces réseaux vivent **derrière le NAT de votre nœud** : ils sont identiques sur tous
les postes de la salle sans jamais entrer en conflit, exactement comme six box Internet
qui distribuent toutes du `192.168.1.0/24`.

---

## 2. Vérifier les prérequis 🖥️

```bash
# dnsmasq installé mais NON actif en service système
dpkg -l dnsmasq | tail -1
systemctl is-enabled dnsmasq        # → disabled
systemctl is-active dnsmasq         # → inactive

# Le routage IP
sysctl net.ipv4.ip_forward          # → 1

# Le TP07 est bien nettoyé
ip -br a | grep vmbr1               # → aucune sortie
iptables -t nat -L POSTROUTING -n | grep 10\\.        # → aucune sortie

# Le dépôt de la formation, sur le nœud : c'est la première fois qu'on s'en sert ici
# (scripts et fichiers de référence du SDN). Il restera utile aux TP 09, 10, 16…
[ -d /root/formation ] || git clone <url-du-depot> /root/formation
ls /root/formation/lab/sdn/standalone/
```

🪤 Si `dnsmasq` est actif, le DHCP du SDN ne démarrera pas (port 67 occupé).

---

## 3. Voir l'IPAM 📇

🌐 `Datacenter → SDN → Options`

Un IPAM `pve` existe déjà par défaut. C'est la base interne de Proxmox
(`/etc/pve/priv/ipam.db`). On l'utilise tel quel.

```bash
pvesh get /cluster/sdn/ipams
```

---

## 4. Créer la zone `zint` 🌐

`Datacenter → SDN → Zones → Add → Simple`

| Champ | Valeur |
|---|---|
| ID | `zint` |
| Nodes | vide (= tous les nœuds — il n'y en a qu'un) |
| IPAM | `pve` |
| Automatic DHCP | ✅ |
| MTU | vide (1500) |

Puis la zone `zdmz`, à l'identique.

### En CLI

```bash
pvesh create /cluster/sdn/zones --zone zint --type simple --ipam pve --dhcp dnsmasq
pvesh create /cluster/sdn/zones --zone zdmz --type simple --ipam pve --dhcp dnsmasq
pvesh get /cluster/sdn/zones
```

🧠 Pas de `--nodes` : sans cette option, la zone s'applique à **tous** les nœuds — et
vous n'en avez qu'un. Elle servira au jour 4, pour restreindre une zone à une partie du
cluster.

🧠 **`--dhcp dnsmasq`** est ce qui déclenche la création d'une instance dnsmasq dédiée
par zone. Sans cette option, l'IPAM attribuera bien des IP mais rien ne les distribuera.

---

## 5. Créer les VNets 🔌

`Datacenter → SDN → VNets → Create`

| Champ | `vint` | `vdmz` |
|---|---|---|
| Name | `vint` | `vdmz` |
| Alias | `Réseau interne` | `DMZ` |
| Zone | `zint` | `zdmz` |
| Tag | vide | vide |
| VLAN Aware | non | non |
| Isolate Ports | non | non |

```bash
pvesh create /cluster/sdn/vnets --vnet vint --zone zint --alias "Reseau interne"
pvesh create /cluster/sdn/vnets --vnet vdmz --zone zdmz --alias "DMZ"
```

🪤 **Nom de VNet : 8 caractères alphanumériques maximum**, et il devient un nom
d'interface Linux. `vint` et `vdmz` respectent la contrainte.

---

## 6. Créer les Subnets 🏷️

Sélectionnez `vint` → onglet **Subnets** → **Create**.

**Onglet Subnet**
| Champ | Valeur |
|---|---|
| Subnet | `10.10.10.0/24` |
| Gateway | `10.10.10.1` |
| SNAT | ✅ |
| DNS zone prefix | vide |

**Onglet DHCP Ranges**
| Start | End |
|---|---|
| `10.10.10.100` | `10.10.10.200` |

Idem pour `vdmz` avec `10.10.20.0/24`.

```bash
pvesh create /cluster/sdn/vnets/vint/subnets \
  --subnet 10.10.10.0/24 --type subnet --gateway 10.10.10.1 --snat 1 \
  --dhcp-range start-address=10.10.10.100,end-address=10.10.10.200

pvesh create /cluster/sdn/vnets/vdmz/subnets \
  --subnet 10.10.20.0/24 --type subnet --gateway 10.10.20.1 --snat 1 \
  --dhcp-range start-address=10.10.20.100,end-address=10.10.20.200
```

> 💡 Tout ce chapitre (zones, VNets, subnets, apply) est scripté dans
> `/root/formation/lab/scripts/sdn-simple-bootstrap.sh`, et les fichiers de référence
> sont dans `/root/formation/lab/sdn/standalone/` — à copier tels quels dans
> `/etc/pve/sdn/`, rien à adapter.

---

## 7. Appliquer ⚡

C'est **l'étape que tout le monde oublie**. Tant que vous n'appliquez pas, la
configuration reste en attente (statut *pending*, écrit en italique dans l'UI).

🌐 `Datacenter → SDN → Apply`

```bash
pvesh set /cluster/sdn
```

### Vérifier ce qui a été généré

```bash
# Les fichiers de configuration : version souhaitée vs version appliquée
ls -l /etc/pve/sdn/
diff /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg && echo "✔ synchronisé"
cat /etc/pve/sdn/subnets.cfg

# Les interfaces réellement créées
cat /etc/network/interfaces.d/sdn
ip -br a | grep -E 'vint|vdmz'
```

Vous devez voir :

```
vint    UNKNOWN  10.10.10.1/24
vdmz    UNKNOWN  10.10.20.1/24
```

```bash
# Le NAT généré automatiquement : Proxmox écrit directement dans POSTROUTING
iptables -t nat -S POSTROUTING | grep -E '10\.[0-9]+\.[0-9]+\.0/24'

# Les instances DHCP
systemctl status dnsmasq@zint --no-pager | head -5
systemctl status dnsmasq@zdmz --no-pager | head -5
ls /etc/dnsmasq.d/
```

Pour le NAT, vous devez voir une ligne par subnet en SNAT, du type :

```
-A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -m mark --mark 0x0/0x80000000 -j SNAT --to-source <IP-de-votre-nœud>
```

🧠 **`iptables` sur Debian 13, c'est `iptables-nft`.** Depuis Debian 10, la commande
`iptables` est une *alternative* qui pointe sur le back-end **nftables** : la règle
ci-dessus **est** une règle nftables, exposée par la couche de compatibilité.
Vérifiez-le :

```bash
iptables -V                # → iptables v1.8.x (nf_tables)   et non (legacy)
nft list table ip nat      # exactement la même règle, vue côté nftables
```

⚠️ **Ne cherchez pas ces règles dans `nft list table inet proxmox-firewall`.** Le
SNAT du SDN et le firewall `proxmox-firewall` (TP 09) vivent dans des **tables
distinctes**, qui ne se voient pas l'une l'autre : `iptables -t nat -S` n'affichera
jamais les règles du firewall, et inversement. C'est la première source de confusion
quand on débogue « je ne trouve pas ma règle ».

🧠 **Prenez trente secondes pour comparer** avec le TP 07 : bridge, IP, `ip_forward`,
MASQUERADE, dnsmasq, plage DHCP, options de routeur — tout ce que vous aviez tapé à la
main a été généré. Et c'est décrit dans quatre fichiers de `/etc/pve`, donc versionnable,
sauvegardable et — dès demain — **répliqué sur les six nœuds**.

---

## 8. Peupler les deux réseaux 🐧🪟🏔️🪨

Pas besoin de créer de nouvelles machines : **on déménage celles des TP 03 à 05.**
C'est aussi l'occasion de voir qu'un changement de bridge est une opération banale.

| Machine | VMID | OS | Nouveau VNet | Rôle |
|---|---|---|---|---|
| `srv01` | `101` | Debian 13 (ISO) | `vint` | Poste d'admin / serveur interne |
| `win01` | `102` | Windows Server 2025 | `vint` | Serveur Windows, RDP |
| `ct-alpine` | `111` | Alpine (LXC) | `vdmz` | Frontal web |
| `ct-rocky` | `112` | Rocky (LXC) | `vdmz` | Second frontal web |

```bash
# --- Zone interne ------------------------------------------------------------
qm set 101 --net0 virtio,bridge=vint,firewall=1,mtu=1
qm set 102 --net0 virtio,bridge=vint,firewall=1,mtu=1

# --- DMZ ---------------------------------------------------------------------
pct set 111 --net0 name=eth0,bridge=vdmz,firewall=1,ip=dhcp
pct set 112 --net0 name=eth0,bridge=vdmz,firewall=1,ip=dhcp
```

🧠 **`mtu=1` sur la carte virtio** signifie « hérite du MTU du bridge ». Ici le bridge
est à 1500, ça ne change rien — mais **au jour 4, en EVPN à 1450, ce réglage sera
vital**. Prenez l'habitude dès maintenant.

### Faire reprendre un bail aux machines

`srv01` et `win01` sont **déjà en DHCP** depuis leur installation (TP 03 et 04) : elles
n'ont rien à changer à l'intérieur, il leur suffit de redemander un bail — c'est
maintenant le `dnsmasq@zint` du SDN qui répond, plus le routeur de la salle. Un
redémarrage fait l'affaire :

```bash
pct reboot 111 ; pct reboot 112 ; qm reboot 101 ; qm reboot 102
```

> 🪤 Si vous aviez mis une IP **statique** dans une VM (une adresse du LAN salle
> attribuée par le formateur, faute de DHCP), repassez-la en DHCP avant :
>
> **Debian** (`qm terminal 101`) :
> ```bash
> sudo sed -i 's/^iface ens18 inet static/iface ens18 inet dhcp/' /etc/network/interfaces
> sudo sed -i '/address\|gateway\|netmask/d' /etc/network/interfaces
> sudo systemctl restart networking
> ```
> **Windows** (console noVNC, PowerShell) :
> ```powershell
> $if = (Get-NetAdapter | Where-Object Status -eq 'Up').ifIndex
> Remove-NetIPAddress -InterfaceIndex $if -Confirm:$false
> Remove-NetRoute -InterfaceIndex $if -Confirm:$false -ErrorAction SilentlyContinue
> Set-NetIPInterface -InterfaceIndex $if -Dhcp Enabled
> Set-DnsClientServerAddress -InterfaceIndex $if -ResetServerAddresses
> ipconfig /renew
> ```

### Vérifier l'attribution par l'IPAM

🌐 `Datacenter → SDN → IPAM` : le tableau liste chaque IP, sa VM et sa MAC.

```bash
pvesh get /cluster/sdn/ipam/pve/status --output-format json | jq -r \
  '.[] | "\(.ip)\t\(.vmid // "-")\t\(.hostname // "-")\t\(.mac // "-")"'
```

```bash
for id in 101 102; do
  echo -n "VM $id : "
  qm agent $id network-get-interfaces 2>/dev/null \
    | jq -r '[.[]|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")|."ip-address"]|join(" ")'
done
pct exec 111 -- ip -4 -br a show eth0
pct exec 112 -- ip -4 -br a show eth0
```

✅ Vous devez voir des adresses en `10.10.10.1xx` (interne) et `10.10.20.1xx` (DMZ).

---

## 9. Tester la connectivité 🔬

### Depuis `srv01` (zone interne)

```bash
qm terminal 101      # Ctrl+O pour sortir
```

```bash
ip -br a ; ip route
ping -c2 10.10.10.1       # gateway locale        → OK
ping -c2 1.1.1.1          # Internet via SNAT     → OK
curl -sI https://deb.debian.org | head -1
ping -c2 10.10.20.100     # une machine de la DMZ → OK (rien ne bloque encore !)
```

### Depuis Windows

```powershell
Test-NetConnection 10.10.10.1
Test-NetConnection 1.1.1.1
Test-NetConnection 10.10.20.100 -Port 80
```

### Depuis votre PC 💻

La route posée au TP 07 couvre déjà ces réseaux (`10.10.0.0/16 via $PVE`) :

```bash
PVE=172.30.30.___                         # ⚠ l'IP de VOTRE nœud
ip route | grep 10.10.0.0 || sudo ip route add 10.10.0.0/16 via $PVE   # si elle a sauté
ping -c2 <IP-de-srv01>                    # 10.10.10.1xx
ssh eleve@<IP-de-srv01> hostname          # ✅ direct : le nœud route, le PC entre
curl -sI http://<IP-de-ct-alpine>/ | head -1
```

🧠 Le SNAT du subnet ne concerne que le trafic **sortant** des VM vers le LAN et
Internet. Dans l'autre sens, le nœud route simplement — tant que son firewall le
permet, ce qui sera l'affaire du TP 09.

🚨 **Constat important** : `vint` et `vdmz` sont **deux réseaux différents, mais l'hôte
route entre les deux** — et depuis le LAN de la salle vers chacun d'eux. Rien n'est
cloisonné. Un serveur compromis en DMZ atteint directement votre serveur Windows et son
RDP.

C'est exactement le problème que le **TP 09** va résoudre.

### Préparer les services pour le TP 09

Sur `ct-alpine` (DMZ) — nginx est déjà installé au TP 05 :

```bash
pct exec 111 -- sh -c 'rc-service nginx status || rc-service nginx start'
pct exec 111 -- sh -c 'echo "<h1>Alpine en DMZ 🏔️</h1>" > /var/lib/nginx/html/index.html'
```

Sur `ct-rocky` (DMZ) :

```bash
pct exec 112 -- bash -c 'systemctl enable --now nginx; echo "<h1>Rocky en DMZ 🪨</h1>" > /usr/share/nginx/html/index.html'
```

Sur `srv01` (interne), on simule une base de données :

```bash
qm terminal 101
sudo apt install -y postgresql netcat-openbsd
sudo systemctl enable --now postgresql
sudo ss -tlnp | grep 5432
```

Sur `win01`, RDP est déjà actif (TP 04) : ce sera notre cible de test « service
interne sensible » au TP 09.

---

## 10. Sous le capot 🔬

Où sont passées les commandes que vous n'avez pas tapées ?

```bash
# Le bridge et son IP : générés
grep -A8 'iface vint' /etc/network/interfaces.d/sdn

# Le NAT : dans la table « ip nat », via iptables-nft
iptables -t nat -S POSTROUTING | grep -E '10\.[0-9]+\.'
nft list table ip nat | head -20

# Le firewall : dans une table SÉPARÉE (une fois nftables activé au TP 09)
nft list table inet proxmox-firewall 2>/dev/null | head -30

# Le DHCP : généré, une instance par zone
cat /etc/dnsmasq.d/zint/* 2>/dev/null || ls -R /etc/dnsmasq.d/
journalctl -u dnsmasq@zint -n 20 --no-pager

# Les interfaces tap des VM, rattachées au bon bridge
bridge link show | grep -E 'vint|vdmz'
```

Capture en direct :

```bash
tcpdump -ni vint -c 10
tcpdump -ni vdmz icmp -c 5
```

---

## 11. Modifier et ré-appliquer 🔁

Faites une modification, par exemple élargir la plage DHCP :

```bash
pvesh set /cluster/sdn/vnets/vint/subnets/zint-10.10.10.0-24 \
  --dhcp-range start-address=10.10.10.60,end-address=10.10.10.200
```

🌐 Observez : dans l'UI, le subnet passe en *pending* (italique).

```bash
diff /etc/pve/sdn/subnets.cfg /etc/pve/sdn/subnets.running.cfg
pvesh set /cluster/sdn                       # Apply
diff /etc/pve/sdn/subnets.cfg /etc/pve/sdn/subnets.running.cfg && echo "✔"
```

🧠 **Le SDN est transactionnel.** Vous pouvez préparer une refonte complète du réseau,
la relire, et l'appliquer d'un seul coup. C'est un vrai avantage opérationnel.

---

## 12. En cas de pépin 🔧

| Symptôme | Piste |
|---|---|
| Le VNet n'apparaît pas dans `ip -br a` | Apply oublié → `pvesh set /cluster/sdn` |
| Pas d'IP en DHCP | `systemctl status dnsmasq@<zone>` ; `systemctl is-active dnsmasq` doit être **inactive** |
| IP obtenue mais pas d'Internet | SNAT non coché sur le subnet ; `sysctl net.ipv4.ip_forward` |
| Gateway injoignable | Le subnet n'a pas de `gateway` définie |
| « zone already exists » | Nettoyer avec `pvesh delete /cluster/sdn/zones/<zone>` (supprimer d'abord subnets puis vnets) |
| Bridge présent mais VM isolée | La VM est sur `vmbr0`, pas sur `vint` : `qm config <id> \| grep net0` |

Script de remise à zéro complet : `/root/formation/lab/scripts/reset-sdn.sh`.

---

## ✅ Checklist de validation

- [ ] Les zones `zint` et `zdmz` existent et sont appliquées (pas de *pending*)
- [ ] `ip -br a` montre `vint` en `10.10.10.1/24` et `vdmz` en `10.10.20.1/24`
- [ ] Depuis mon PC, `ssh eleve@<IP-de-srv01>` répond directement (route du TP 07)
- [ ] Les 4 machines ont obtenu une IP **par DHCP**
- [ ] L'écran IPAM liste ces IP avec leur VMID
- [ ] Chaque machine ping Internet (SNAT fonctionnel)
- [ ] `curl http://<ip-alpine>/` depuis `srv01` fonctionne (et c'est un **problème**)
- [ ] Je sais dire quelles commandes du TP 07 ont été remplacées par quelles cases à cocher
- [ ] `systemctl status dnsmasq@zint` est actif

---

## 🎁 Bonus

1. **Port isolation** : activez `Isolate Ports` sur `vdmz`, ré-appliquez, et vérifiez
   que `ct-alpine` ne ping plus `ct-rocky` mais ping toujours sa gateway. De la
   micro-segmentation en une case à cocher.
2. Créez une zone **sans SNAT** et constatez : les VM se parlent entre elles et joignent
   la gateway, mais pas Internet. C'est le comportement voulu pour un réseau de
   sauvegarde ou de réplication.
3. Sauvegardez toute la configuration SDN :
   `tar czf /root/sdn-$(date +%F).tgz /etc/pve/sdn/` — puis lisez les fichiers, ils sont
   parfaitement lisibles.

➡️ Suite : [TP 09 — Firewall inter-zones](09-firewall-inter-zones.md)
