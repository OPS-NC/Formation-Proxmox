# TP 16 — Mise en cluster des 6 nœuds 🔗

⏱️ **1 h 15** · Jour 4

Objectif : fusionner six hyperviseurs indépendants en un seul cluster Proxmox.
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

## 2. ⚠️ Préparation obligatoire

**Un nœud ne peut rejoindre un cluster que s'il n'héberge aucune VM ni conteneur.**
Et rejoindre un cluster **écrase `/etc/pve`** — donc votre configuration SDN, firewall
et vos utilisateurs.

### 2.1 Sauvegarder tout ce qui compte

**Les guests, vers PBS** (TP 15) — c'est la sauvegarde qui compte :

```bash
N=3
vzdump --pool eleve$N --storage pbs-lab --mode snapshot --compress zstd
pvesm list pbs-lab
```

🌐 Sur PBS : `Datastore → lab-store → <namespace> → Verify`.
🚨 **Ne continuez pas si la vérification n'est pas verte.** Vous allez détruire les
originaux.

**Les configurations**, qui ne sont pas dans les sauvegardes de guests :

```bash
mkdir -p /root/pre-cluster
tar czf /root/pre-cluster/conf-$(hostname)-$(date +%F).tgz \
    /etc/pve/sdn /etc/pve/firewall /etc/pve/nodes/$(hostname)/host.fw \
    /etc/pve/storage.cfg /etc/pve/user.cfg \
    /etc/network/interfaces /etc/hosts 2>/dev/null

cp /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf /root/pre-cluster/ 2>/dev/null
ls -lh /root/pre-cluster/
```

Récupérez tout sur votre PC — il est dehors, lui :

```bash
scp -r root@192.168.50.1N:/root/pre-cluster ~/ProxmoxFormation/backup-conf/
```

🧠 **Ce que PBS ne sauvegarde pas** : la configuration du nœud (`/etc/pve`), les
templates, et les ISO. D'où ce `tar`. Dans une vraie exploitation, `/etc/pve` part dans
une sauvegarde de configuration séparée, versionnée dans Git si possible.

### 2.2 Supprimer les guests

```bash
for id in $(qm list | awk 'NR>1{print $1}') ; do qm stop $id 2>/dev/null; sleep 2; qm destroy $id --purge; done
for id in $(pct list | awk 'NR>1{print $1}') ; do pct stop $id 2>/dev/null; sleep 1; pct destroy $id --purge; done
qm list ; pct list
```

> 💡 Les **templates** aussi doivent partir. On les reconstruira en 5 minutes avec
> `build-template.sh` (§7.4). C'est justement pourquoi on a industrialisé au TP 10.
>
> ⚠️ **`pve1` fait exception** : il *crée* le cluster, donc il conserve ses guests —
> dont la VM `pbs-lab`. Ne la détruisez surtout pas, c'est elle qui contient les
> sauvegardes de toute la salle.

### 2.3 Nettoyer le SDN local

```bash
bash /root/formation/lab/scripts/reset-sdn.sh
pvesh get /cluster/sdn/zones      # doit être vide
ip -br a | grep -E 'vint|vdmz|vsrv'    # aucune sortie
```

### 2.4 Vérifications finales

```bash
qm list && pct list                       # vides
hostname --ip-address                     # 192.168.50.1N, pas 127.x
ping -c1 pve1 && ping -c1 pve2 && ping -c1 pve3 \
  && ping -c1 pve4 && ping -c1 pve5 && ping -c1 pve6
timedatectl status | grep -E 'synchron|Time zone'
pveversion                                # MÊME version sur tous les nœuds
systemctl status corosync --no-pager | head -3
```

🪤 **Versions différentes = mise en cluster refusée ou instable.** Si un nœud est en
retard : `apt update && apt full-upgrade && reboot`.

---

## 3. Créer le cluster (sur `pve1` uniquement) 🖥️

Un seul élève, l'élève 1, exécute ceci :

```bash
pvecm create FORMATION --link0 192.168.50.11
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

## 4. Rejoindre le cluster (élèves 2 à 6) 🔗

**Un nœud à la fois.** Attendez que le précédent soit `Quorate: Yes` avant de lancer
le suivant. Six `pvecm add` simultanés, c'est le meilleur moyen de tout casser.

```bash
pvecm add 192.168.50.11 --link0 192.168.50.1N
```

Il demande :
- l'empreinte SSH de `pve1` → `yes`
- le mot de passe root de `pve1` → `Formation2026!`

Puis :

```
Please wait while the node is joined...
successfully added node 'pveN' to cluster.
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
2. Sur `pveN` : `Datacenter → Cluster → Join Cluster`, coller, saisir le mot de passe
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

`/etc/pve/firewall/cluster.fw` est maintenant **commun aux six nœuds**. L'élève 1
le remet en place, tout le monde en bénéficie :

```bash
cp /root/formation/lab/firewall/cluster.fw.example /etc/pve/firewall/cluster.fw
vim /etc/pve/firewall/cluster.fw     # vérifier la règle Corosync 5405:5412 !
pve-firewall compile | head -20
```

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

`/etc/pve/storage.cfg` est maintenant **commun aux six nœuds**. Vos déclarations des
TP 14 et 15 ont disparu avec le reste de `/etc/pve`. On les refait — et cette fois
une seule déclaration suffit pour tout le cluster.

**PBS** — une seule personne le fait, c'est cluster-wide :

```bash
pvesm add pbs pbs-lab \
  --server 192.168.50.41 --datastore lab-store \
  --username eleve1@pbs --password 'Formation2026!' \
  --fingerprint '<empreinte relevée au TP 15>' \
  --content backup
pvesm status
```

Vérifiez depuis un autre nœud : `pbs-lab` y apparaît tout seul. 🎩

**Le NFS de chaque poste** — chacun sur son nœud :

```bash
N=3
pvesm add nfs nfs-e$N \
  --server 192.168.50.10$N --export /srv/nfs-e$N \
  --content images,rootdir,iso,backup,snippets \
  --options vers=4.2 --nodes pve$N
```

🪤 **N'oubliez pas `--nodes pveN`.** Sans lui, les six nœuds tenteraient de monter votre
partage — qui n'autorise que votre IP — et le signaleraient en erreur toutes les
30 secondes dans l'interface de **tout le monde**.

> 💡 Chaque élève peut aussi ajouter un stockage `pbs-eN` pointant sur **son** namespace
> (`--namespace eleveN --nodes pveN`), pour ne voir que ses propres sauvegardes.

🧠 Le stockage réellement partagé et redondé arrivera au **TP 18** avec Ceph :
`vm-store` et `cephfs`, visibles et utilisables depuis les six nœuds.

### 7.3 Restaurer vos guests depuis PBS 🔄

C'est maintenant que le TP 15 paie. Vos machines sont dans PBS, le cluster est monté :
restaurez-les.

```bash
N=3
pvesm list pbs-lab | grep "vm/$((N))"
qm restore ${N}01 pbs-lab:backup/vm/${N}01/<timestamp> --storage local-lvm
qm restore ${N}02 pbs-lab:backup/vm/${N}02/<timestamp> --storage local-lvm
pct restore ${N}11 pbs-lab:backup/ct/${N}11/<timestamp> --storage local-lvm
qm list ; pct list
```

⚠️ **Respectez votre plage de VMID** : dans un cluster à six, un VMID en doublon est
purement refusé. C'est le plan du TP 00 qui vous sauve ici.

### 7.4 Reconstruire les templates

Un template n'existe que sur son nœud (stockage local, non sauvegardé). Chacun refait
les siens — en cinq minutes, parce qu'on les a industrialisés au TP 10 :

```bash
N=3     # ⚠ VOTRE numéro d'élève
cd /root/formation
./lab/scripts/build-template.sh --eleve N --os debian13   --vmid ${N}90
./lab/scripts/build-template.sh --eleve N --os ubuntu2604 --vmid ${N}91
./lab/scripts/build-template.sh --eleve N --os rocky10    --vmid ${N}92
```

🧠 **C'est le retour sur investissement du jour 3.** Sans les scripts, Terraform et
Ansible, reconstruire l'environnement après la mise en cluster prendrait la matinée.
Là, il suffit de rejouer `terraform apply` puis `ansible-playbook site.yml`.

🌐 Dans `Datacenter → Search`, vous voyez maintenant les templates de tout le monde.
D'où l'importance du plan de VMID.

### 7.5 Recréer les pools

```bash
for i in 1 2 3 4 5 6; do pvesh create /pools --poolid eleve$i 2>/dev/null; done
pvesh get /pools
```

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

- [ ] `pvecm status` : `Nodes: 6`, `Quorate: Yes`, `Quorum: 4`
- [ ] `pvecm nodes` liste les six nœuds avec le bon numéro d'ID
- [ ] L'interface web d'un nœud affiche les six
- [ ] Un fichier créé dans `/etc/pve` sur un nœud apparaît sur les autres
- [ ] J'ai vu `/etc/pve` passer en lecture seule pendant la perte de quorum
- [ ] Le firewall du datacenter autorise Corosync (5405-5412)
- [ ] Mes guests sont restaurés depuis PBS
- [ ] Mes templates sont reconstruits
- [ ] Les stockages `pbs-lab` et `nfs-eN` sont déclarés et actifs
- [ ] Mon pool `eleveN` existe
- [ ] La VM `pbs-lab` sur pve1 n'a **pas** été détruite
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
