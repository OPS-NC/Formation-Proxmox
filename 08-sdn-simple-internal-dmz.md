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
                          192.168.50.254
                                   │
   ══════════════ LAN salle 192.168.50.0/24 ══════════════
                                   │
                              ┌────┴────┐
                              │  vmbr0  │
                              └────┬────┘
                                   │
                          ╔════════╧════════╗
                          ║   NŒUD pveN     ║
                          ║   SNAT ×2       ║
                          ╚═══╤═════════╤═══╝
                    zone zint │         │ zone zdmz
                      vnet    │         │   vnet
                     ┌────────┴──┐   ┌──┴─────────┐
                     │   vint    │   │    vdmz    │
                     │ 10.N.10.0 │   │ 10.N.20.0  │
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
| `vint` | `zint` | `10.N.10.0/24` | `10.N.10.1` | `.100-.200` | ✅ | Back-office, bases |
| `vdmz` | `zdmz` | `10.N.20.0/24` | `10.N.20.1` | `.100-.200` | ✅ | Services exposés |

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
```

🪤 Si `dnsmasq` est actif, le DHCP du SDN ne démarrera pas (port 67 occupé).

---

## 3. Activer l'IPAM 📇

🌐 `Datacenter → SDN → IPAM`

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
| Nodes | `pveN` |
| IPAM | `pve` |
| Automatic DHCP | ✅ |
| MTU | vide (1500) |

Puis la zone `zdmz`, à l'identique.

### En CLI

```bash
N=3
pvesh create /cluster/sdn/zones --zone zint --type simple --nodes pve$N --ipam pve --dhcp dnsmasq
pvesh create /cluster/sdn/zones --zone zdmz --type simple --nodes pve$N --ipam pve --dhcp dnsmasq
pvesh get /cluster/sdn/zones
```

🧠 **`--dhcp dnsmasq`** est ce qui déclenche la création d'une instance dnsmasq dédiée
par zone. Sans cette option, l'IPAM attribuera bien des IP mais rien ne les distribuera.

---

## 5. Créer les VNets 🔌

`Datacenter → SDN → VNets → Create`

| Champ | `vint` | `vdmz` |
|---|---|---|
| Name | `vint` | `vdmz` |
| Alias | `Réseau interne eN` | `DMZ eN` |
| Zone | `zint` | `zdmz` |
| Tag | vide | vide |
| VLAN Aware | non | non |
| Isolate Ports | non | non |

```bash
pvesh create /cluster/sdn/vnets --vnet vint --zone zint --alias "Reseau interne e$N"
pvesh create /cluster/sdn/vnets --vnet vdmz --zone zdmz --alias "DMZ e$N"
```

🪤 **Nom de VNet : 8 caractères alphanumériques maximum**, et il devient un nom
d'interface Linux. `vint` et `vdmz` respectent la contrainte.

---

## 6. Créer les Subnets 🏷️

Sélectionnez `vint` → onglet **Subnets** → **Create**.

**Onglet Subnet**
| Champ | Valeur |
|---|---|
| Subnet | `10.N.10.0/24` |
| Gateway | `10.N.10.1` |
| SNAT | ✅ |
| DNS zone prefix | vide |

**Onglet DHCP Ranges**
| Start | End |
|---|---|
| `10.N.10.100` | `10.N.10.200` |

Idem pour `vdmz` avec `10.N.20.0/24`.

```bash
N=3
pvesh create /cluster/sdn/vnets/vint/subnets \
  --subnet 10.$N.10.0/24 --type subnet --gateway 10.$N.10.1 --snat 1 \
  --dhcp-range start-address=10.$N.10.100,end-address=10.$N.10.200

pvesh create /cluster/sdn/vnets/vdmz/subnets \
  --subnet 10.$N.20.0/24 --type subnet --gateway 10.$N.20.1 --snat 1 \
  --dhcp-range start-address=10.$N.20.100,end-address=10.$N.20.200
```

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
vint    UNKNOWN  10.3.10.1/24
vdmz    UNKNOWN  10.3.20.1/24
```

```bash
# Le NAT généré automatiquement
iptables -t nat -L PVESDN-SNAT -n -v 2>/dev/null || nft list ruleset | grep -A5 snat

# Les instances DHCP
systemctl status dnsmasq@zint --no-pager | head -5
systemctl status dnsmasq@zdmz --no-pager | head -5
ls /etc/dnsmasq.d/
```

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
| `srv01-eN` | `N01` | Debian 13 (ISO) | `vint` | Poste d'admin / serveur interne |
| `win01-eN` | `N02` | Windows Server 2025 | `vint` | Serveur Windows, RDP |
| `ct-alpine-eN` | `N11` | Alpine (LXC) | `vdmz` | Frontal web |
| `ct-rocky-eN` | `N12` | Rocky (LXC) | `vdmz` | Second frontal web |

```bash
N=3

# --- Zone interne ------------------------------------------------------------
qm set N01 --net0 virtio,bridge=vint,firewall=1,mtu=1
qm set N02 --net0 virtio,bridge=vint,firewall=1,mtu=1

# --- DMZ ---------------------------------------------------------------------
pct set N11 --net0 name=eth0,bridge=vdmz,firewall=1,ip=dhcp
pct set N12 --net0 name=eth0,bridge=vdmz,firewall=1,ip=dhcp
```

🧠 **`mtu=1` sur la carte virtio** signifie « hérite du MTU du bridge ». Ici le bridge
est à 1500, ça ne change rien — mais **au jour 4, en EVPN à 1450, ce réglage sera
vital**. Prenez l'habitude dès maintenant.

### Repasser les VM en DHCP

`srv01` et `win01` ont une IP statique du LAN salle configurée **à l'intérieur** du
système. Il faut les repasser en DHCP pour que l'IPAM fasse son travail.

**Debian** (`srv01`, console `qm terminal N01`) :

```bash
sudo sed -i 's/^iface ens18 inet static/iface ens18 inet dhcp/' /etc/network/interfaces
sudo sed -i '/address\|gateway\|netmask/d' /etc/network/interfaces
sudo systemctl restart networking
ip -br a
```

**Windows** (`win01`, console noVNC, PowerShell) :

```powershell
$if = (Get-NetAdapter | Where-Object Status -eq 'Up').ifIndex
Remove-NetIPAddress -InterfaceIndex $if -Confirm:$false
Remove-NetRoute -InterfaceIndex $if -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceIndex $if -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $if -ResetServerAddresses
ipconfig /renew
ipconfig /all
```

```bash
pct reboot N11 ; pct reboot N12 ; qm reboot N01 ; qm reboot N02
```

### Vérifier l'attribution par l'IPAM

🌐 `Datacenter → SDN → IPAM` : le tableau liste chaque IP, sa VM et sa MAC.

```bash
pvesh get /cluster/sdn/ipam/pve/status --output-format json | jq -r \
  '.[] | "\(.ip)\t\(.vmid // "-")\t\(.hostname // "-")\t\(.mac // "-")"'
```

```bash
for id in N01 N02; do
  echo -n "VM $id : "
  qm agent $id network-get-interfaces 2>/dev/null \
    | jq -r '[.[]|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")|."ip-address"]|join(" ")'
done
pct exec N11 -- ip -4 -br a show eth0
pct exec N12 -- ip -4 -br a show eth0
```

✅ Vous devez voir des adresses en `10.N.10.1xx` (interne) et `10.N.20.1xx` (DMZ).

---

## 9. Tester la connectivité 🔬

### Depuis `srv01` (zone interne)

```bash
qm terminal N01      # Ctrl+O pour sortir
```

```bash
ip -br a ; ip route
ping -c2 10.3.10.1        # gateway locale        → OK
ping -c2 9.9.9.9          # Internet via SNAT     → OK
curl -sI https://deb.debian.org | head -1
ping -c2 10.3.20.100      # une machine de la DMZ → OK (rien ne bloque encore !)
```

### Depuis Windows

```powershell
Test-NetConnection 10.3.10.1
Test-NetConnection 9.9.9.9
Test-NetConnection 10.3.20.100 -Port 80
```

🚨 **Constat important** : `vint` et `vdmz` sont **deux réseaux différents, mais l'hôte
route entre les deux**. Rien n'est cloisonné. Un serveur compromis en DMZ atteint
directement votre serveur Windows et son RDP.

C'est exactement le problème que le **TP 09** va résoudre.

### Préparer les services pour le TP 09

Sur `ct-alpine-eN` (DMZ) — nginx est déjà installé au TP 05 :

```bash
pct exec N11 -- sh -c 'rc-service nginx status || rc-service nginx start'
pct exec N11 -- sh -c 'echo "<h1>Alpine en DMZ 🏔️</h1>" > /var/lib/nginx/html/index.html'
```

Sur `ct-rocky-eN` (DMZ) :

```bash
pct exec N12 -- bash -c 'systemctl enable --now nginx; echo "<h1>Rocky en DMZ 🪨</h1>" > /usr/share/nginx/html/index.html'
```

Sur `srv01-eN` (interne), on simule une base de données :

```bash
qm terminal N01
sudo apt install -y postgresql netcat-openbsd
sudo systemctl enable --now postgresql
sudo ss -tlnp | grep 5432
```

Sur `win01-eN`, RDP est déjà actif (TP 04) : ce sera notre cible de test « service
interne sensible » au TP 09.

---

## 10. Sous le capot 🔬

Où sont passées les commandes que vous n'avez pas tapées ?

```bash
# Le bridge et son IP : générés
grep -A8 'iface vint' /etc/network/interfaces.d/sdn

# Le NAT : généré (iptables ou nftables selon la configuration du nœud)
iptables -t nat -S | grep -i sdn
nft list table ip proxmox-firewall 2>/dev/null | head -30

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
pvesh set /cluster/sdn/vnets/vint/subnets/zint-10.3.10.0-24 \
  --dhcp-range start-address=10.3.10.50,end-address=10.3.10.200
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

Script de remise à zéro complet : `lab/scripts/reset-sdn.sh`.

---

## ✅ Checklist de validation

- [ ] Les zones `zint` et `zdmz` existent et sont appliquées (pas de *pending*)
- [ ] `ip -br a` montre `vint` en `10.N.10.1/24` et `vdmz` en `10.N.20.1/24`
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
