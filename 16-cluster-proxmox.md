# TP 16 — Réinstallation et mise en cluster des 6 nœuds 🔗

⏱️ **2 h 30** · Jour 4

Objectif : repartir de six nœuds propres, puis les fusionner en un seul cluster Proxmox.
Comprendre Corosync, le quorum, et ce qui se passe quand ça se passe mal.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pvecm.html>

> ⚠️ **TP collectif.** Tout le monde avance ensemble. Le formateur donne le top départ
> à chaque étape.

---

## 1. Ce qu'est un cluster Proxmox 🧠

Deux composants, à ne pas confondre :

```
   ┌──────────────────────────────────────────────────────────────┐
   │  COROSYNC                                                    │
   │  Le bus de messages temps réel entre nœuds.                  │
   │  · UDP 5405-5412, multicast ou unicast                       │
   │  · détecte les pannes en quelques centaines de ms            │
   │  · calcule le QUORUM                                         │
   │  · EXTRÊMEMENT sensible à la latence (< 2 ms exigé)          │
   └───────────────────────────┬──────────────────────────────────┘
                               │
   ┌───────────────────────────▼──────────────────────────────────┐
   │  PMXCFS  →  /etc/pve                                         │
   │  Système de fichiers distribué (SQLite + Corosync).          │
   │  · tout ce qu'on y écrit est répliqué sur TOUS les nœuds     │
   │  · configs VM, SDN, firewall, users, storage                 │
   │  · devient LECTURE SEULE si le quorum est perdu 🔒           │
   └──────────────────────────────────────────────────────────────┘
```

### Le quorum

Un cluster de **N** nœuds a besoin de **⌊N/2⌋ + 1** votes pour être *quorate*.

| Nœuds | Quorum requis | Pannes tolérées |
|---|---|---|
| 2 | 2 | **0** ⚠️ |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |
| **6** | **4** | **2** |
| 7 | 4 | 3 |

🧠 **Pourquoi ?** Pour empêcher le *split-brain*. Si le réseau se coupe en deux moitiés
de 3 nœuds, aucune n'a le quorum, donc aucune ne démarre les VM de l'autre. Mieux vaut
un cluster figé qu'un cluster où la même VM tourne deux fois et corrompt son disque.

🪤 **Le cluster à 2 nœuds est un piège** : la perte d'un seul nœud fige l'autre.
Solution : un **QDevice** (§8) — une petite machine tierce qui apporte un vote.

---

## 2. ⚠️ Réinstaller les nœuds

### 2.1 Pourquoi on réinstalle 🧠

Pendant trois jours, les six nœuds ont été **rigoureusement identiques** : même
hostname `pve`, mêmes VMID (`101`, `102`, `111`…), mêmes subnets `10.10.x.0/24`, même
pool `lab`. C'était voulu — chacun était seul chez lui, aucune convention de
numérotation à retenir.

Un cluster, lui, exige des **hostnames uniques** et des **VMID uniques** sur les six
machines. Et de toute façon :

- un nœud ne peut rejoindre un cluster que s'il **n'héberge aucun guest** ;
- rejoindre un cluster **écrase `/etc/pve`** — SDN, firewall, stockages, utilisateurs.

Renommer un nœud Proxmox à chaud est possible mais piégeux (répertoires dans
`/etc/pve/nodes/`, certificats, configs de VM à déplacer). Détruire tous les guests
puis rebaptiser six machines, c'est plus long et plus risqué qu'une **réinstallation
propre de 15 minutes** — qui, en prime, vous donne une seconde chance sur `maxvz`.
C'est la voie la plus rapide et la plus honnête.

### 2.2 Sauvegarder ce qui doit survivre 💾

Tout ce qui vit sur votre nœud va disparaître, **y compris votre VM PBS**. Le seul
stockage qui survit est **l'export NFS de votre poste** (TP 14) : déposez-y ce que vous
voulez garder.

```bash
# Les guests que vous tenez à revoir (ex. cloud01, votre clone cloud-init du TP 10)
vzdump 120 --storage nfs-pc --mode snapshot --compress zstd
ls -lh /mnt/pve/nfs-pc/dump/

# Les configurations, qui ne sont dans aucune sauvegarde de guest
mkdir -p /mnt/pve/nfs-pc/conf
tar czf /mnt/pve/nfs-pc/conf/conf-$(date +%F).tgz \
    /etc/pve/sdn /etc/pve/firewall /etc/pve/nodes/$(hostname)/host.fw \
    /etc/pve/storage.cfg /etc/pve/user.cfg \
    /etc/network/interfaces /etc/hosts 2>/dev/null
cp /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf /mnt/pve/nfs-pc/conf/ 2>/dev/null
ls -lh /mnt/pve/nfs-pc/conf/
```

> 💡 Le stagiaire dont le nœud deviendra **`pve1`** peut aussi sauvegarder sa VM PBS
> (`vzdump 901 --storage nfs-pc --mode stop`) : c'est elle qui servira de PBS à toute
> la salle au §7.2, à moins de préférer la réinstaller (10 minutes).

🧠 Pas besoin de `scp` : l'export NFS **est** votre PC. Tout ce que vous venez de
déposer est déjà dans `/srv/nfs/conf/` et `/srv/nfs/dump/` sur votre poste — il est
dehors, lui.

🧠 **Ce qui n'a pas besoin d'être sauvegardé** : les templates, les VM Terraform, les
snippets cloud-init, le code Ansible. Tout cela se reconstruit en quelques commandes —
c'est **le retour sur investissement du jour 3**. Dans une vraie exploitation,
`/etc/pve` part dans une sauvegarde de configuration séparée, versionnée dans Git.

### 2.3 Le tableau de la salle 🗺️

Le formateur attribue les noms. **Chacun garde l'IP qu'il avait** : seul le hostname
change.

| Nœud | Hostname (FQDN) | IP | Rôles au jour 4 |
|---|---|---|---|
| `pve1` | `pve1.lab.local` | `172.30.30.151` | crée le cluster · exit node primaire · PBS et Pulse · MON + MGR Ceph |
| `pve2` | `pve2.lab.local` | `172.30.30.152` | exit node secondaire · MON + MGR Ceph |
| `pve3` | `pve3.lab.local` | `172.30.30.153` | MON Ceph |
| `pve4` | `pve4.lab.local` | `172.30.30.154` | |
| `pve5` | `pve5.lab.local` | `172.30.30.155` | |
| `pve6` | `pve6.lab.local` | `172.30.30.156` | |

### 2.4 Réinstaller 🏗️

Rejouez le [TP 01 §3](01-installation-proxmox.md) **à l'identique**, avec deux
différences :

| Champ | Jours 1-3 | **Jour 4** |
|---|---|---|
| Hostname (FQDN) | `pve.lab.local` | **`pveX.lab.local`** selon le tableau |
| IP | `$PVE/24` | `$PVE/24` — inchangée |
| `maxvz` | … | ⭐ **réduisez-le** (TP 01 §3.1 bis) : 80 Go libres dans le VG |

🎯 **`maxvz` : votre seconde chance.** Si vous l'aviez laissé par défaut au jour 1,
c'est le moment de le régler : le TP 18 (Ceph) se fera alors en trois commandes
(« chemin A ») au lieu d'une chirurgie LVM.

Puis rejouez le [TP 01 §5 et §6](01-installation-proxmox.md) : dépôts
`no-subscription`, `apt full-upgrade`, paquets, `dnsmasq` désactivé, fuseau horaire.

```bash
apt install -y vim tmux htop iftop tcpdump ethtool bridge-utils \
               frr frr-pythontools dnsmasq git proxmox-firewall
systemctl disable --now dnsmasq
timedatectl set-timezone Pacific/Noumea    # ou Europe/Paris
```

🪤 **`proxmox-firewall` n'est pas dans l'installation de base.** C'est lui qui donne
un sens à `nftables: 1` dans `host.fw` (TP 09 §2). Sans lui, les règles VNet du TP 17
sont ignorées **en silence** — le piège n°1 du TP 09, à ne pas retrouver au jour 4.

Et depuis votre PC, la clé SSH :

```bash
PVE=172.30.30.___            # ⚠ l'IP de VOTRE nœud
ssh-keygen -R $PVE           # l'ancienne empreinte du nœud n'est plus valable
ssh-copy-id root@$PVE
ssh root@$PVE hostname       # → pveX
```

### 2.5 Résolution de noms : les six nœuds 📇

Sur **chaque** nœud, `/etc/hosts` doit connaître toute la salle :

```
127.0.0.1       localhost.localdomain localhost
172.30.30.151   pve1.lab.local pve1
172.30.30.152   pve2.lab.local pve2
172.30.30.153   pve3.lab.local pve3
172.30.30.154   pve4.lab.local pve4
172.30.30.155   pve5.lab.local pve5
172.30.30.156   pve6.lab.local pve6
```

🪤 **La ligne de votre propre nœud doit contenir votre vraie IP**, pas `127.0.1.1`.
Sinon Corosync s'annonce sur la loopback et le cluster ne se forme pas.

```bash
hostname --ip-address     # doit renvoyer votre IP en 172.30.30.x, pas 127.x
```

### 2.6 Vérifications finales

```bash
qm list && pct list                       # vides : nœud neuf
hostname ; hostname --ip-address          # pveX, et votre IP
for n in 1 2 3 4 5 6; do ping -c1 -W1 pve$n >/dev/null && echo "pve$n OK" || echo "pve$n KO"; done
timedatectl status | grep -E 'synchron|Time zone'
pveversion                                # MÊME version sur tous les nœuds
systemctl status corosync --no-pager | head -3
```

🪤 **Versions différentes = mise en cluster refusée ou instable.** Si un nœud est en
retard : `apt update && apt full-upgrade && reboot`.

---

## 3. Créer le cluster (sur `pve1` uniquement) 🖥️

Un seul stagiaire — celui dont le nœud est `pve1` — exécute ceci :

```bash
pvecm create FORMATION --link0 172.30.30.151
```

```bash
pvecm status
```

Sortie attendue :

```
Cluster information
-------------------
Name:             FORMATION
Config Version:   1
Transport:        knet
Secure auth:      on

Quorum information
------------------
Nodes:            1
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   1
Highest expected: 1
Total votes:      1
Quorum:           1
```

```bash
cat /etc/pve/corosync.conf
```

🧠 **`--link0`** définit le réseau utilisé par Corosync. En production, on lui dédie un
VLAN ou une carte, séparés du trafic de stockage et de migration : quelques
millisecondes de latence supplémentaires suffisent à provoquer des faux positifs de
panne. Ici, avec un seul LAN, on n'a pas le choix — et c'est une limite du lab à
mentionner en soutenance.

---

## 4. Rejoindre le cluster (les cinq autres nœuds) 🔗

**Un nœud à la fois.** Attendez que le précédent soit `Quorate: Yes` avant de lancer
le suivant. Cinq `pvecm add` simultanés, c'est le meilleur moyen de tout casser.

```bash
pvecm add 172.30.30.151 --link0 $(hostname --ip-address)
```

Il demande :
- l'empreinte SSH de `pve1` → `yes`
- le mot de passe root de `pve1` → `Formation2026!`

Puis :

```
Please wait while the node is joined...
successfully added node 'pve3' to cluster.
```

⚠️ **Votre session web est cassée** : le certificat du nœud a été régénéré et
`/etc/pve` remplacé. Rechargez la page (Ctrl+Shift+R) et reconnectez-vous.

Sur n'importe quel nœud :

```bash
pvecm status
pvecm nodes
```

À six :

```
Nodes:            6
Quorate:          Yes
Expected votes:   6
Total votes:      6
Quorum:           4
```

🌐 L'interface web de **n'importe quel** nœud montre maintenant les six.

### Alternative : le Join Information 🌐

Sans SSH ni mot de passe partagé :
1. Sur `pve1` : `Datacenter → Cluster → Join Information → Copy Information`
2. Sur votre nœud : `Datacenter → Cluster → Join Cluster`, coller, saisir le mot de passe
   root de `pve1`, valider.

C'est la méthode recommandée quand plusieurs personnes opèrent.

---

## 5. Explorer le cluster 🔬

```bash
# La vue globale
pvesh get /cluster/resources --output-format table
pvecm nodes
ha-manager status 2>/dev/null

# Corosync en détail
corosync-quorumtool -s
corosync-cfgtool -s          # état des liens (link0, latence)
journalctl -u corosync -n 30 --no-pager

# pmxcfs
ls -l /etc/pve/nodes/        # un répertoire par nœud, sur TOUS les nœuds
cat /etc/pve/.members
```

### La démonstration qui marque 💡

Sur `pve1` :

```bash
echo "Bonjour depuis pve1 $(date)" > /etc/pve/salut.txt
```

Sur `pve5`, instantanément :

```bash
cat /etc/pve/salut.txt
```

🧠 **C'est ça, pmxcfs.** Un fichier écrit sur un nœud existe sur les six en quelques
millisecondes. C'est pourquoi le SDN, le firewall et les configs de VM sont
automatiquement cohérents partout — et pourquoi le TP 17 va pouvoir déployer un réseau
sur six nœuds en une seule opération.

```bash
rm /etc/pve/salut.txt
```

---

## 6. Comprendre la perte de quorum 🧪

**Expérience collective, sous la direction du formateur.**

Trois nœuds (`pve4`, `pve5`, `pve6`) coupent Corosync :

```bash
systemctl stop corosync
```

Sur `pve1` (3 nœuds restants sur 6, quorum = 4) :

```bash
pvecm status
```

```
Quorate:          No     ← 🔴
Total votes:      3
Quorum:           4  Activity blocked
```

```bash
touch /etc/pve/test-quorum
# → touch: cannot touch '/etc/pve/test-quorum': Permission denied
```

🧠 **`/etc/pve` est passé en lecture seule.** Vous ne pouvez plus créer, modifier ni
démarrer de VM. Les VM **déjà démarrées continuent de tourner** — Proxmox ne les tue
pas. C'est un choix délibéré : préserver le service existant, empêcher toute nouvelle
décision potentiellement conflictuelle.

Remise en service :

```bash
systemctl start corosync
pvecm status                      # Quorate: Yes
```

### Le forçage d'urgence (à connaître, à ne jamais utiliser à la légère)

```bash
pvecm expected 3      # abaisse temporairement le quorum attendu
```

🚨 **Danger absolu** : si l'autre moitié du cluster est vivante et fait la même chose,
vous obtenez deux clusters qui se croient légitimes. Deux instances de la même VM
écrivant sur le même disque partagé = corruption garantie. À réserver aux
récupérations de sinistre, quand on est **certain** que l'autre moitié est morte.

---

## 7. Adapter la configuration au cluster 🔧

### 7.1 Rétablir le firewall

`/etc/pve/firewall/cluster.fw` est maintenant **commun aux six nœuds**. Le stagiaire de
`pve1` (ou le formateur) le met en place, tout le monde en bénéficie :

```bash
[ -d /root/formation ] || git clone <url-du-depot> /root/formation   # le nœud est neuf
cp /root/formation/lab/firewall/cluster.fw.example /etc/pve/firewall/cluster.fw
vim /etc/pve/firewall/cluster.fw     # vérifier la règle Corosync 5405:5412
pve-firewall compile | head -20
```

Le fichier d'exemple porte aussi les règles `FORWARD lan_salle → net_evpn` : c'est ce
qui permettra à votre PC de joindre les VM EVPN du TP 17 directement.

🪤 **Sans la règle Corosync, activer le firewall casse le cluster.** Vérifiez avant :

```ini
IN ACCEPT -source lan_salle -p udp -dport 5405:5412 -log nolog # Corosync — VITAL
```

Chaque nœud garde son `host.fw` :

```bash
cat > /etc/pve/nodes/$(hostname)/host.fw <<'EOF'
[OPTIONS]
enable: 1
nftables: 1
log_level_in: nolog
log_level_forward: info
EOF
```

### 7.2 Re-déclarer les stockages 💾

`/etc/pve/storage.cfg` est **commun aux six nœuds**, et il ne contient plus que `local`
et `local-lvm` : les nœuds sont neufs. On redéclare — et cette fois, une seule déclaration suffit pour tout le cluster.

**PBS** — la VM PBS de la salle vit sur **`pve1`**. Le stagiaire de `pve1` (ou le
formateur) la recrée, au choix :

```bash
# Option A : la restaurer depuis le NFS de son poste (sauvegardée au §2.2)
PC=172.30.30.___             # ⚠ l'IP du poste du stagiaire de pve1
pvesm add nfs nfs-pve1 --server $PC --export /srv/nfs \
  --content images,rootdir,iso,backup,snippets --options vers=4.2 --nodes pve1
qmrestore /mnt/pve/nfs-pve1/dump/vzdump-qemu-901-*.vma.zst 901 --storage local-lvm
qm start 901

# Option B : la réinstaller — TP 15 §2 à §4, une dizaine de minutes
```

Puis, **une seule personne**, depuis n'importe quel nœud :

```bash
PBS=172.30.30.___            # ⚠ l'adresse de la VM PBS de la salle
pvesm add pbs pbs-lab \
  --server $PBS --datastore lab-store --namespace lab \
  --username eleve@pbs --password 'Formation2026!' \
  --fingerprint '<empreinte : proxmox-backup-manager cert info sur la VM PBS>' \
  --content backup
pvesm status
```

Vérifiez depuis un autre nœud : `pbs-lab` y apparaît tout seul. 🎩

**Le NFS de chaque poste** — chacun sur son nœud :

```bash
PC=172.30.30.___             # ⚠ l'IP de VOTRE poste (hostname -I)
pvesm status | grep -q "^nfs-$(hostname) " || \
pvesm add nfs nfs-$(hostname) \
  --server $PC --export /srv/nfs \
  --content images,rootdir,iso,backup,snippets \
  --options vers=4.2 --nodes $(hostname)
pvesm status
```

> Le stagiaire de `pve1` l'a déjà fait à l'option A : le garde-fou `grep -q` évite le
> `storage ID 'nfs-pve1' already defined`.

🪤 **En cluster, `--nodes` n'est plus optionnel.** L'ID du stockage doit être unique
dans le cluster (d'où `nfs-pve3` plutôt que `nfs-pc`), et sans `--nodes`, les six nœuds
tenteraient de monter votre partage — qui n'autorise que votre IP — et le signaleraient
en erreur toutes les 30 secondes dans l'interface de **tout le monde**.

🧠 Le stockage réellement partagé et redondé arrivera au **TP 18** avec Ceph :
`vm-store` et `cephfs`, visibles et utilisables depuis les six nœuds.

### 7.3 Restaurer depuis votre NFS — ce qui a survécu 🔄

Facultatif, mais instructif : la sauvegarde déposée au §2.2 est là, sur un nœud
réinstallé, dans un cluster qui n'existait pas quand elle a été faite.

```bash
ls /mnt/pve/nfs-$(hostname)/dump/
NEW=$(pvesh get /cluster/nextid)
qmrestore /mnt/pve/nfs-$(hostname)/dump/vzdump-qemu-120-*.vma.zst $NEW --storage local-lvm
qm set $NEW --delete cicustom     # le snippet pointait sur « nfs-pc », qui n'existe plus
qm list
```

🪤 **`--delete cicustom`** : si `cloud01` a gardé le `--cicustom vendor=nfs-pc:snippets/…`
du TP 14, la VM restaurée refuse de démarrer (`storage 'nfs-pc' does not exist`). Le
stockage s'appelle désormais `nfs-<nœud>` — le TP 14 retirait déjà ce réglage en fin
de TP, ceci est le filet de sécurité.

🧠 **En cluster, le VMID est unique pour les six nœuds.** Ne choisissez plus vos numéros
à la main : `pvesh get /cluster/nextid` rend le prochain VMID libre du cluster, et
l'interface web le propose d'elle-même. C'est ce qu'on fera pour toutes les machines du
jour 4.

🪤 Deux stagiaires qui lancent `nextid` à la même seconde obtiennent le même numéro :
le second `qm create` échoue avec `VM already exists`. Relancez, c'est tout.

### 7.4 Reconstruire les templates

Un template n'existe que sur son nœud (stockage local). Chacun refait les siens — en
cinq minutes, parce qu'on les a industrialisés au TP 10. Le nœud est neuf : commencez
par y recloner le dépôt.

```bash
[ -d /root/formation ] || git clone <url-du-depot> /root/formation
cd /root/formation
./lab/scripts/build-template.sh --os debian13   --vmid $(pvesh get /cluster/nextid)
./lab/scripts/build-template.sh --os ubuntu2604 --vmid $(pvesh get /cluster/nextid)
./lab/scripts/build-template.sh --os rocky10    --vmid $(pvesh get /cluster/nextid)
qm list | grep tpl-          # notez VOS trois VMID, les TP 17 et 18 s'en servent
```

🧠 **C'est le retour sur investissement du jour 3.** Sans les scripts, Terraform et
Ansible, reconstruire l'environnement après la mise en cluster prendrait la matinée.
Là, il suffit de rejouer `terraform apply` puis `ansible-playbook site.yml`.

🌐 Dans `Datacenter → Search`, vous voyez maintenant les templates de tout le monde :
six `tpl-debian13`, avec six VMID différents. Filtrez sur votre nœud.

### 7.5 Recréer le pool

Un seul pool, partagé, comme aux jours 1-3 — une seule personne le crée :

```bash
pvesh create /pools --poolid lab --comment "Ressources de la formation"
pvesh get /pools
```

### 7.6 Comptes, tokens et poste de travail 🔑

`/etc/pve/user.cfg` a disparu avec la réinstallation : les comptes et tokens du
[TP 06 §7](06-exploration-interface.md) n'existent plus. En cluster, ils sont
**cluster-wide** — **une seule personne** les recrée, tout le monde en profite :

```bash
pveum user add eleve@pve --password 'Formation2026!' --comment "Compte de TP"
pveum aclmod / --users eleve@pve --roles PVEAdmin

pveum role add TerraformProv -privs "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit SDN.Allocate SDN.Audit SDN.Use Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt User.Modify"
pveum user add terraform@pve --comment "Provisioning Terraform"
pveum aclmod / --users terraform@pve --roles TerraformProv
pveum user token add terraform@pve tf --privsep 0        # 📌 notez le secret

pveum user add ansible@pve --comment "Inventaire dynamique Ansible"
pveum aclmod / --users ansible@pve --roles PVEAuditor
pveum user token add ansible@pve inv --privsep 0         # 📌 notez le secret
```

> La liste des privilèges est celle du TP 06 §7.1.

Puis **chacun, sur son PC**, met à jour ses deux fichiers : le nœud ne s'appelle plus
`pve`, et les tokens ont changé.

```bash
# ~/.config/pve/token.env
export PVE_NODE="pve3"                                   # ⚠ VOTRE nœud
export PVE_API_TOKEN="terraform@pve!tf=<nouveau-secret>"
export PVE_ANSIBLE_TOKEN_SECRET="<nouveau-secret>"

# lab/terraform/*/terraform.tfvars
pve_node      = "pve3"                                   # ⚠ VOTRE nœud
pve_api_token = "terraform@pve!tf=<nouveau-secret>"
```

```bash
source ~/.config/pve/token.env
curl -sk -H "Authorization: PVEAPIToken=$PVE_API_TOKEN" \
  "$PVE_ENDPOINT/api2/json/nodes" | jq -r '.data[].node'       # → les six nœuds
rm -rf /tmp/ansible-pve-cache                                   # le cache d'inventaire Ansible est périmé
```

🧠 **Un seul token Terraform pour six postes ?** C'est un lab. En production, un token
par équipe ou par pipeline, avec des privilèges limités au pool concerné.

---

## 8. QDevice : le vote d'arbitrage 🗳️

Pour illustrer le problème du cluster pair/à deux nœuds.

```
   SANS QDEVICE (2 nœuds)          AVEC QDEVICE
   ──────────────────────          ────────────
      pve1 ─── pve2                   pve1 ─── pve2
       1v      1v                      1v       1v
    quorum = 2                            \     /
    1 panne = tout gèle                    QDev (1v)
                                        quorum = 2 sur 3
                                        1 panne = ça continue ✅
```

Sur une machine tierce (un Raspberry Pi, une VM, le PC du formateur) :

```bash
apt install -y corosync-qnetd
systemctl enable --now corosync-qnetd
```

Sur chaque nœud du cluster :

```bash
apt install -y corosync-qdevice
```

Depuis un nœud :

```bash
pvecm qdevice setup <ip-du-qnetd>
pvecm status                       # Qdevice apparaît avec 1 vote
corosync-qdevice-tool -s
```

🧠 Avec 6 nœuds, le QDevice est inutile (le nombre est pair mais on tolère déjà 2
pannes). Il devient **indispensable** sur les clusters de 2 ou 4 nœuds, très courants
en PME.

---

## 9. Retirer un nœud 🚪

Pour information — **ne le faites pas maintenant**.

```bash
# Depuis un AUTRE nœud, le nœud à retirer étant éteint définitivement
pvecm delnode pve6
pvecm status
```

🪤 **Un nœud retiré ne doit JAMAIS être rallumé sur le même réseau.** Il a encore les
clés Corosync et va tenter de rejoindre le cluster, semant la pagaille. Pour le
réutiliser : réinstallation complète de Proxmox.

Nettoyage des reliquats sur les nœuds restants :

```bash
rm -rf /etc/pve/nodes/pve6      # si le répertoire persiste
```

---

## ✅ Checklist de validation

- [ ] Mon nœud est réinstallé en `pveX` (tableau du §2.3), avec `maxvz` réglé
- [ ] `/etc/hosts` contient les six nœuds, et `hostname --ip-address` renvoie ma vraie IP
- [ ] `pvecm status` : `Nodes: 6`, `Quorate: Yes`, `Quorum: 4`
- [ ] `pvecm nodes` liste les six nœuds avec le bon numéro d'ID
- [ ] L'interface web d'un nœud affiche les six
- [ ] Un fichier créé dans `/etc/pve` sur un nœud apparaît sur les autres
- [ ] J'ai vu `/etc/pve` passer en lecture seule pendant la perte de quorum
- [ ] Le firewall du datacenter autorise Corosync (5405-5412)
- [ ] Mes templates sont reconstruits (`qm list | grep tpl-`)
- [ ] Les stockages `pbs-lab` et `nfs-<nœud>` sont déclarés et actifs
- [ ] Le pool `lab` existe
- [ ] Les comptes `eleve@pve`, `terraform@pve!tf` et `ansible@pve!inv` sont recréés, et mon `token.env` / `terraform.tfvars` pointent sur `pveX`
- [ ] Je sais pourquoi on laisse le cluster choisir les VMID (`pvesh get /cluster/nextid`)
- [ ] Je sais dire combien de pannes tolère un cluster de 6, et pourquoi

---

## 🎁 Bonus

1. **Second link Corosync** : si vos serveurs ont une deuxième carte réseau, ajoutez
   `--link1` pour de la redondance de heartbeat.
   ```bash
   pvecm status ; corosync-cfgtool -s
   ```
2. **Mesurer la latence Corosync** :
   `corosync-cfgtool -s` puis `journalctl -u corosync | grep -i token`.
   Au-delà de 2 ms de latence moyenne, le cluster devient nerveux.
3. Lisez `/etc/pve/corosync.conf` en entier. Repérez `config_version` : il s'incrémente
   à chaque modification et sert à résoudre les conflits de configuration.
4. **Panne simulée** : débranchez physiquement le câble réseau d'un nœud pendant
   30 secondes. Observez `pvecm status` et `journalctl -u corosync -f` sur les autres.

➡️ Suite : [TP 17 — SDN en cluster : EVPN/VXLAN](17-sdn-evpn-cluster.md) 🎉
