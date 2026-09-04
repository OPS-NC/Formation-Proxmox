# TP 07 — Réseau « à l'ancienne » : vmbr1 natté 🔌

⏱️ **45 min** · Jour 2

Objectif : construire à la main un second bridge isolé avec NAT et DHCP. On fait tout
« en dur » **une fois**, pour comprendre ce que le SDN automatisera au TP 08.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysadmin_network_configuration>

---

## 1. Le problème 🧠

Jusqu'ici, toutes vos VM sont sur `vmbr0`, donc **directement sur le LAN de la salle**.
Conséquences :

- elles consomment des IP du réseau `172.30.30.0/24`,
- elles voient les machines des autres stagiaires,
- rien ne les protège,
- vous ne pouvez pas rejouer un plan d'adressage sans conflit.

Ce qu'on veut :

```
   AVANT                                APRÈS
   ─────                                ─────
        LAN salle                            LAN salle
            │                                    │
         vmbr0                                 vmbr0
       ┌────┴────┐                          ┌────┴────┐
      VM        VM                        (hôte seul)
                                              │ NAT + ip_forward
                                            vmbr1  10.10.99.1/24
                                          ┌───┴───┐
                                         VM       VM
                                    10.10.99.x  (DHCP)
```

---

## 2. Créer le bridge 🖥️

Un bridge **sans `bridge-ports`** n'est relié à aucune carte physique : c'est un switch
purement virtuel, interne au nœud.

### Via l'interface web 🌐
`pve → System → Network → Create → Linux Bridge`

| Champ | Valeur |
|---|---|
| Name | `vmbr1` |
| IPv4/CIDR | `10.10.99.1/24` |
| Gateway | **vide** ⚠️ |
| Bridge ports | **vide** |
| Autostart | ✅ |
| Comment | `LAN NAT manuel - TP07` |

🪤 **Ne mettez pas de gateway** sur `vmbr1`. Un système Linux n'a qu'une seule route par
défaut ; en mettre une seconde ici casserait l'accès au nœud. La gateway `10.10.99.1`,
c'est l'IP du bridge lui-même, vue **depuis les VM**.

Cliquez **Apply Configuration** (PVE 9 applique à chaud grâce à `ifupdown2`, sans reboot).

### Ou en CLI

Éditez `/etc/network/interfaces` :

```
auto vmbr1
iface vmbr1 inet static
        address 10.10.99.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        comment LAN NAT manuel - TP07
```

```bash
ifreload -a
ip -br a show vmbr1
```

---

## 3. Activer le routage et le NAT

### 3.1 Routage IP

```bash
cat > /etc/sysctl.d/99-lab-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system
sysctl net.ipv4.ip_forward
```

### 3.2 SNAT (masquerade)

```bash
iptables -t nat -A POSTROUTING -s 10.10.99.0/24 -o vmbr0 -j MASQUERADE
iptables -t nat -L POSTROUTING -n -v
```

🧠 **MASQUERADE vs SNAT** : `MASQUERADE` détermine l'IP source dynamiquement à partir de
l'interface de sortie (utile en DHCP/PPP, un peu plus coûteux). `SNAT --to-source
<IP-de-votre-nœud>` est statique et plus rapide. Sur un serveur à IP fixe, `SNAT` est le
choix correct.

### 🧠 « Debian 13, ce n'est pas nftables ? » — si, et vous venez d'en écrire

Depuis Debian 10, la commande `iptables` est une *alternative* qui pointe sur
**`iptables-nft`** : elle parle au moteur **nftables** du noyau via la couche de
compatibilité `nft_compat`. La règle que vous venez de taper est une règle nftables.

```bash
iptables -V                     # → iptables v1.8.11 (nf_tables)   et non (legacy)
update-alternatives --display iptables
nft list table ip nat           # votre MASQUERADE, vue depuis nftables
```

```
   iptables -t nat -A POSTROUTING ...        nft add rule ip nat postrouting ...
              │                                          │
              └────────► nft_compat ────────► table « ip nat » du noyau ◄──┘
                        (traduction)              (le SEUL moteur)
```

Trois nuances qui comptent pour la suite :

| | |
|---|---|
| **`iptables-legacy` existe encore** | Mais rien ne l'utilise. Le vrai piège n'est pas nft *vs* iptables, c'est de **mélanger** les deux back-ends sur le même hook : deux jeux de règles invisibles l'un pour l'autre. |
| **Les tables ne se voient pas entre elles** | Vos règles vivent dans la table `ip nat`. Le `proxmox-firewall` du TP 09 crée les siennes dans `inet proxmox-firewall`. `iptables -t nat -S` n'affichera **jamais** les règles du firewall, et inversement. |
| **`nftables: 1` (TP 09) ne touche pas à ce NAT** | Cette option bascule le *firewall* Proxmox, pas votre masquerade. Les deux cohabitent : hooks `nat` et `filter` sont indépendants. |

👉 On garde `iptables` parce que c'est ce qu'on trouve dans la plupart des tutoriels et
scripts existants. Vous savez maintenant ce qui tourne dessous.

### 3.3 Rendre persistant

Les règles iptables disparaissent au reboot. Deux approches :

```bash
# Option A — un hook dans /etc/network/interfaces (simple, lisible)
cat >> /etc/network/interfaces <<'EOF'

# NAT pour vmbr1 (TP07)
        post-up   iptables -t nat -A POSTROUTING -s 10.10.99.0/24 -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s 10.10.99.0/24 -o vmbr0 -j MASQUERADE
EOF
# ⚠ ces lignes doivent être INDENTÉES sous la strophe « iface vmbr1 »
```

```bash
# Option B — iptables-persistent
apt install -y iptables-persistent
netfilter-persistent save
```

```bash
# Option C — nftables natif, sans couche de compatibilité
nft add table ip lab-nat
nft add chain ip lab-nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule  ip lab-nat postrouting ip saddr 10.10.99.0/24 oifname vmbr0 masquerade

nft list ruleset > /etc/nftables.conf     # persistance
systemctl enable --now nftables
```

🧠 A et B produisent le même résultat dans le noyau que C, seul le vocabulaire change.
C est plus verbeux mais explicite : table, chaîne, hook, priorité. C'est la structure
que vous retrouverez dans `nft list ruleset` au TP 09.

🪤 C'est ce bricolage que le SDN supprime : au TP 08, la même chose tient en une case à
cocher, répliquée sur le cluster.

---

## 4. Un DHCP pour vmbr1 🎫

Sans DHCP, chaque VM se configure à la main. On lance dnsmasq avec une configuration
dédiée : le service a été désactivé au TP 01 parce que le SDN en aura besoin.

```bash
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/vmbr1-tp07.conf <<'EOF'
interface=vmbr1
bind-interfaces
except-interface=lo
dhcp-range=10.10.99.100,10.10.99.200,12h
dhcp-option=option:router,10.10.99.1
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
log-dhcp
EOF

systemctl enable --now dnsmasq
systemctl status dnsmasq --no-pager | head -5
```

📌 En fin de TP, dnsmasq sera de nouveau désactivé : le TP 08 utilise les instances
`dnsmasq@<zone>` du SDN.

---

## 5. Tester ✅

Un conteneur Alpine jetable :

```bash
TPL=$(pveam list local | awk '/alpine/ {print $1}' | head -1)

pct create 119 $TPL --hostname ct-nat --pool lab \
  --unprivileged 1 --password 'Formation2026!' \
  --rootfs local-lvm:2 --cores 1 --memory 256 \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --start 1

sleep 5
pct exec 119 -- ip -4 -br a show eth0
```

Dans le conteneur :

```bash
pct exec 119 -- sh -c '
  ip -br a
  ip route
  ping -c2 10.10.99.1       # la gateway = l'"'"'hôte
  ping -c2 172.30.30.2   # le routeur de la salle → passe grâce au NAT
  ping -c2 1.1.1.1          # Internet
  apk update
'
```

🎁 Refaites le même test avec votre VM Debian du TP 03 :

```bash
qm set 101 --net0 virtio,bridge=vmbr1,firewall=1
qm reboot 101
# la VM est en DHCP depuis le TP 03 : elle prend une adresse en 10.10.99.x
# … puis remettez-la sur vmbr0 à la fin du TP
```

Sur l'hôte :

```bash
watch -n1 'iptables -t nat -L POSTROUTING -n -v | tail -3'
conntrack -L 2>/dev/null | grep 10.10.99 | head
tcpdump -ni vmbr1 -c 10
```

### Et depuis votre PC ? 💻

Le NAT fait sortir les guests, pas entrer. Votre PC ne connaît pas `10.10.99.0/24` : sa
seule route est la route par défaut vers la box. La gateway de ce réseau est votre
nœud, il suffit de le dire au PC :

```bash
PVE=172.30.30.___                 # ⚠ l'IP de VOTRE nœud
sudo ip route add 10.10.0.0/16 via $PVE
ip route | grep 10.10
ping -c2 <IP-du-CT-119>           # ✅ le PC joint le conteneur, sans passer par le nœud
```

🧠 Un `/16`, une seule fois : tous les réseaux privés du nœud (`vmbr1` aujourd'hui, les
VNets `10.10.10/20/30` dès le TP 08) sont dans `10.10.0.0/16`. Cette route reste en
place jusqu'au jour 4. Dans cette formation, on ne rebondit jamais par le nœud en SSH :
on route.

🪤 La route disparaît au redémarrage du PC : relancez la commande ou rendez-la
permanente (netplan, NetworkManager). Quand « ça ne répond plus » : `ip route | grep 10.10`.

---

## 6. Les limites de cette approche 🧠

| Limite | Conséquence |
|---|---|
| Configuration **locale au nœud** | Il faut la refaire, identique, sur les 6 nœuds |
| Le nom `vmbr1` doit exister partout | Sinon la migration d'une VM échoue |
| Pas de L2 entre nœuds | Deux VM `10.10.99.x` sur deux nœuds ne se voient pas |
| Règles iptables à la main | Non versionnées, non auditées, oubliées au prochain reboot |
| Pas d'IPAM | Qui a quelle IP ? Personne ne sait |
| Pas de firewall inter-réseaux structuré | Tout est à écrire soi-même |
| Écrasé par le SDN | Si le SDN reprend la main, conflits possibles |

👉 C'est le cahier des charges du SDN :

```
   TP 07 — à la main                    TP 08 — SDN
   ──────────────────                   ───────────
   éditer /etc/network/interfaces       Datacenter → SDN → créer une zone
   sysctl ip_forward                    (automatique)
   iptables MASQUERADE                  cocher « SNAT »
   dnsmasq.conf à écrire                cocher « DHCP » + une plage
   noter les IP dans un tableur         IPAM intégré
   × 6 nœuds                            × 1 (répliqué par pmxcfs)
```

---

## 7. Nettoyage avant le TP 08 🧹

> 💡 **Ne supprimez pas la route `10.10.0.0/16` ajoutée sur votre PC** : elle sert dès
> le TP 08 pour joindre les VNets SDN.

On remet le nœud dans un état propre avant le SDN.

```bash
# 1. Supprimer le conteneur de test, et remettre srv01 sur vmbr0 si vous l'avez déplacé
pct stop 119 ; sleep 2 ; pct destroy 119 --purge
qm set 101 --net0 virtio,bridge=vmbr0,firewall=1

# 2. Rendre dnsmasq au SDN
systemctl disable --now dnsmasq
rm -f /etc/dnsmasq.d/vmbr1-tp07.conf

# 3. Retirer la règle NAT
iptables -t nat -D POSTROUTING -s 10.10.99.0/24 -o vmbr0 -j MASQUERADE
iptables -t nat -S POSTROUTING
nft delete table ip lab-nat 2>/dev/null || true   # si vous aviez pris l'option C

# 4. Supprimer vmbr1 (interface web : System → Network → vmbr1 → Remove → Apply)
#    ou retirer la strophe de /etc/network/interfaces puis :
ifreload -a
ip -br a
```

On garde `net.ipv4.ip_forward = 1` : le SDN en a besoin de toute façon.

---

## ✅ Checklist de validation

- [ ] `vmbr1` existe avec `10.10.99.1/24` et **aucun** port physique
- [ ] Un guest sur `vmbr1` obtient une IP par DHCP
- [ ] Ce guest ping `1.1.1.1` et met à jour ses paquets
- [ ] Je vois les compteurs de la règle MASQUERADE augmenter
- [ ] Mon PC a la route `10.10.0.0/16 via $PVE` et ping le conteneur directement
- [ ] Je sais citer **trois** limites de cette approche manuelle
- [ ] Je sais expliquer pourquoi `iptables` sur Debian 13 écrit en réalité du nftables
- [ ] Le nettoyage est fait : plus de `vmbr1`, plus de règle NAT, dnsmasq désactivé

---

## 🎁 Bonus

1. **Publier un service** : faites du DNAT pour exposer le port 80 d'une VM de `vmbr1`
   sur le port 8080 de l'hôte.
   ```bash
   iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 8080 \
            -j DNAT --to-destination 10.10.99.100:80
   iptables -A FORWARD -d 10.10.99.100 -p tcp --dport 80 -j ACCEPT
   ```
   Testez depuis votre PC : `curl http://$PVE:8080/`. Puis supprimez les règles.
2. Refaites le bridge en **OVS** (`apt install openvswitch-switch`, type
   *OVS Bridge*). Comparez `ovs-vsctl show` avec `brctl show`.
3. Créez un **bond** LACP fictif (`bond0` en `balance-alb` sur une seule NIC, pour voir
   la syntaxe) — ne l'appliquez pas si vous n'avez qu'une carte réseau !

➡️ Suite : [TP 08 — SDN : zones internal et dmz](08-sdn-simple-internal-dmz.md)
