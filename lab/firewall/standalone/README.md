# Firewall standalone — TP 09 à 15

Ces fichiers sont distincts des exemples historiques du dossier parent, utilisés par
la formation cluster. Aucun TP 16+ ni règle EVPN n'est à appliquer ici.

`cluster.fw.example` va dans `/etc/pve/firewall/cluster.fw` **même en standalone**.
Les trois autres exemples vont dans `/etc/pve/sdn/firewall/<vnet>.fw`.
Au TP 09, copier uniquement vint et vdmz ; au TP 12, Terraform prend en charge le
Datacenter et vsrv. Le modèle Datacenter de ce dossier restaure l'état **TP 09**, pas
la matrice SERVICES du TP 12.

Avant toute copie : conserver une session SSH ouverte et une console de secours,
sauvegarder les fichiers existants, vérifier `lan_salle = 172.30.30.0/24` et les routes
du poste (`10.10.0.0/16 via <IP-PVE>`). Suivre l'ordre d'activation du TP 09 : installer
les autorisations avant les politiques DROP. Ne pas écraser une configuration réelle
personnalisée avec ces exemples.

## Répartition des règles

- Datacenter INPUT : administration PVE depuis le LAN et DHCP/DNS/ping des gateways.
- Datacenter FORWARD : LAN → invités et matrice inter-zones / sorties Internet.
- VNet FORWARD : DHCP, DNS/ping gateway et communications entre invités du même VNet.
- Invité INPUT : services réellement exposés ; toujours TCP 22 depuis `lan_salle`.
- OS invité : service SSH actif, compte/clé configurés, firewall local compatible.

Les retours établis sont traités par conntrack. Autoriser un nouveau flux A → B
n'autorise pas une nouvelle connexion B → A. Une règle sans destination ne signifie
pas « Internet uniquement » : les refus inter-zones doivent la précéder.

Le LAN dispose de SSH, HTTP(S), PostgreSQL et ICMP vers les réseaux du lab ; au TP 12,
3000/9090 sont aussi accessibles vers SERVICES. Les autorisations réseau n'installent
ni PostgreSQL, ni Grafana, ni OpenSSH Windows. Ne pas désactiver les firewalls invités
pour rendre un test vert ; ajouter les autorisations ciblées nécessaires.

## Recette

Depuis le poste Linux du LAN, après préparation des services et des clés (TP 09 §7) :

```bash
bash lab/scripts/test-firewall-standalone.sh --int 10.10.10.100 --dmz 10.10.20.101
# Après le TP 13, ajouter --services <IP-mon01> --exporter <IP-app01>.
```

Ce script ne démarre aucun service et ne modifie aucun firewall. Il exige un listener
temporaire sur DMZ:8080 (et SERVICES:8080 avec l'option correspondante), afin de ne pas
confondre un port sans service avec une interdiction réseau. Aucun test obligatoire
n'est ignoré : un prérequis absent provoque un code 2, un flux inattendu un code 1.
Contrôler séparément SSH vers tous les autres invités, PVE et PBS depuis le LAN.

Contrôles de non-régression locaux (sans Proxmox ni connexion réseau) :

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s lab/tests -v
terraform -chdir=lab/terraform/03-sdn-troisieme-lan validate
```

Pour inspecter le moteur actif, utiliser `nft list ruleset` et
`journalctl -u proxmox-firewall`. `pve-firewall compile` ne valide pas les règles du
nouveau moteur nftables. Tester aussi un renouvellement DHCP et le DNS TCP/UDP après
redémarrage d'un invité dans chaque VNet. Cette recette IPv4 ne valide pas IPv6.

Références : [documentation firewall Proxmox](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html),
[chaînes du moteur nftables](https://git.proxmox.com/?p=proxmox-firewall.git;a=blob_plain;f=proxmox-firewall/resources/proxmox-firewall.nft;hb=HEAD).
