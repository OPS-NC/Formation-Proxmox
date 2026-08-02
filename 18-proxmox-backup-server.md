# TP 18 — Proxmox Backup Server 💾

⏱️ **1 h 30** · Jour 4

Objectif : installer PBS, le brancher au cluster, sauvegarder, restaurer, et comprendre
pourquoi la déduplication change complètement l'économie de la sauvegarde.

📖 Doc : <https://pbs.proxmox.com/docs/>

---

## 1. `vzdump` vs PBS 🧠

Vous avez déjà fait des sauvegardes avec `vzdump` (TP 03). Comparons.

```
   VZDUMP                                PROXMOX BACKUP SERVER
   ──────                                ─────────────────────
   Une archive complète par sauvegarde   Découpage en CHUNKS de ~4 Mo
                                         indexés par leur empreinte SHA-256

   J1 : 20 Go                            J1 : 20 Go  (500 chunks)
   J2 : 20 Go                            J2 : +0,2 Go (5 chunks nouveaux)
   J3 : 20 Go                            J3 : +0,1 Go
   ─────────                             ──────────
   60 Go                                 20,3 Go   → ~66 % d'économie

   Restauration : tout ou rien           Restauration : VM entière, OU
                                         un seul fichier, OU live-restore
   Pas de vérification                   Vérification cryptographique
   Pas de chiffrement                    Chiffrement AES-256 côté client
```

🧠 **La déduplication est globale au datastore.** Six VM Debian identiques ne stockent
qu'**un seul** exemplaire des chunks communs. Sur un parc homogène, le taux de
déduplication dépasse couramment 10:1.

```
   VM1  ┐
   VM2  ├──► [chunk A][chunk B][chunk C]  ← stockés UNE fois
   VM3  ┘         ▲        ▲        ▲
                  └────────┴────────┴──── référencés par les 3 index
```

---

## 2. Installer PBS dans une VM 🏗️

> 🤝 **Un seul PBS pour la salle.** Le formateur désigne l'hébergeur (par ex. l'élève 2).
> Les autres suivent, puis effectuent l'étape 5 (branchement) sur leur propre nœud.

### Créer la VM

```bash
qm create 901 \
  --name pbs-lab --pool eleve2 \
  --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32,discard=on,ssd=1 \
  --scsi1 nfs-lab:200,discard=on \
  --ide2 local:iso/proxmox-backup-server_4.x-1.iso,media=cdrom \
  --boot order='ide2;scsi0' \
  --cores 2 --memory 4096 --cpu x86-64-v2-AES \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --agent enabled=1
qm start 901
```

🔗 ISO : <https://www.proxmox.com/en/downloads> → *Proxmox Backup Server*

| Élément | Valeur |
|---|---|
| Disque système | 32 Go |
| **Disque datastore** | 200 Go (`scsi1`) — séparé, toujours |
| RAM | 4 Go minimum (la déduplication est gourmande en index) |
| IP | `192.168.50.41/24`, gw `192.168.50.254` |
| FQDN | `pbs.lab.local` |

L'installateur est le même que celui de PVE. Après le premier démarrage :

```bash
ssh root@192.168.50.41
proxmox-backup-manager version
```

Interface web : **<https://192.168.50.41:8007>** (port **8007**, pas 8006).

### Dépôts sans abonnement

```bash
mv /etc/apt/sources.list.d/pbs-enterprise.sources \
   /etc/apt/sources.list.d/pbs-enterprise.sources.disabled 2>/dev/null

cat > /etc/apt/sources.list.d/pbs-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update && apt full-upgrade -y
```

> 💡 **Alternative** : PBS s'installe aussi par-dessus une Debian 13 existante
> (`apt install proxmox-backup-server`). Pratique pour réutiliser un serveur.

---

## 3. Créer le datastore 🗄️

🌐 `Administration → Storage/Disks → Directory → Create` sur `/dev/sdb`,
ou `Datastore → Add Datastore`.

```bash
# Préparer le disque
proxmox-backup-manager disk list
proxmox-backup-manager disk fs create data --disk sdb --filesystem xfs --add-datastore false

# Créer le datastore
proxmox-backup-manager datastore create lab-store /mnt/datastore/data \
  --comment "Datastore de la formation"

proxmox-backup-manager datastore list
```

### Les namespaces 📂

Un datastore peut être cloisonné en **namespaces** (jusqu'à 8 niveaux). Idéal ici :
chaque élève a le sien, sans voir ceux des autres.

```bash
for i in 1 2 3 4 5 6; do
  proxmox-backup-manager namespace create --store lab-store --ns eleve$i
done
proxmox-backup-manager namespace list --store lab-store
```

```
   lab-store/
   ├── eleve1/     vm/301  vm/302  ct/311
   ├── eleve2/     vm/401  ...
   └── eleve3/     ...
```

🧠 **La déduplication reste globale au datastore**, même entre namespaces. On gagne
l'isolation des droits sans perdre l'économie d'espace. C'est très élégant.

---

## 4. Utilisateurs, droits et empreinte 🔑

```bash
# Un compte par élève, limité à son namespace
for i in 1 2 3 4 5 6; do
  proxmox-backup-manager user create eleve$i@pbs --password 'Formation2026!'
  proxmox-backup-manager acl update /datastore/lab-store/eleve$i \
      DatastoreAdmin --auth-id eleve$i@pbs
done
proxmox-backup-manager acl list
```

| Rôle PBS | Donne |
|---|---|
| `DatastoreAdmin` | tout sur le datastore |
| `DatastoreBackup` | créer et lire **ses propres** sauvegardes ⭐ |
| `DatastoreReader` | lire et restaurer |
| `DatastorePowerUser` | créer, lire, supprimer les siennes |
| `DatastoreAudit` | lecture des métadonnées seulement |

**Récupérez l'empreinte du certificat** — indispensable pour brancher PVE :

```bash
proxmox-backup-manager cert info | grep -i fingerprint
```

```
Fingerprint (sha256): AB:CD:EF:...:12:34
```

📌 Copiez-la : PVE la demandera.

---

## 5. Brancher PBS sur le cluster ⚡

**Une seule déclaration pour les six nœuds** — merci pmxcfs.

🌐 `Datacenter → Storage → Add → Proxmox Backup Server`

| Champ | Valeur |
|---|---|
| ID | `pbs-lab` |
| Server | `192.168.50.41` |
| Username | `eleveN@pbs` |
| Password | `Formation2026!` |
| Datastore | `lab-store` |
| Namespace | `eleveN` |
| Fingerprint | *(collez l'empreinte)* |
| Encryption Key | *(voir §8)* |

```bash
pvesm add pbs pbs-lab \
  --server 192.168.50.41 \
  --datastore lab-store \
  --namespace eleve3 \
  --username eleve3@pbs \
  --password 'Formation2026!' \
  --fingerprint 'AB:CD:EF:...:12:34' \
  --content backup

pvesm status
pvesm list pbs-lab
```

🪤 Empreinte erronée ⇒ `certificate verification failed`. Recopiez-la **sans espaces
parasites**, avec les deux-points.

---

## 6. Sauvegarder 💾

### À la main

```bash
N=3
vzdump N60 --storage pbs-lab --mode snapshot --notes-template '{{guestname}} — {{node}}'
```

Les trois modes :

| Mode | Fonctionnement | Interruption | Cohérence |
|---|---|---|---|
| `stop` | arrête la VM, sauvegarde, redémarre | ⚠️ totale | parfaite |
| `suspend` | fige la VM le temps du snapshot | courte | bonne |
| **`snapshot`** | snapshot à chaud + agent QEMU (fsfreeze) | **aucune** | ⭐ bonne si l'agent tourne |

🧠 **L'agent QEMU fait toute la différence en mode `snapshot`.** Sans lui, on capture un
état « comme si on avait coupé le courant » : le système de fichiers devra rejouer son
journal au démarrage, et une base de données peut être incohérente. Avec l'agent,
Proxmox demande à l'invité de **geler ses systèmes de fichiers** (`fsfreeze`) le temps
du snapshot. C'est la différence entre une sauvegarde qu'on restaure sereinement et une
sauvegarde dont on prie qu'elle marche.

### Un job planifié

🌐 `Datacenter → Backup → Add`

| Champ | Valeur |
|---|---|
| Node | `-- All --` |
| Storage | `pbs-lab` |
| Schedule | `02:30` (ou `mon..fri 02:30`) |
| Selection mode | **Pool based** → `eleveN` ⭐ |
| Mode | `snapshot` |
| Notification mode | `Notification system` |
| **Retention** | `keep-daily=7, keep-weekly=4, keep-monthly=6` |

```bash
pvesh create /cluster/backup \
  --id backup-eleve3 \
  --schedule '02:30' \
  --storage pbs-lab \
  --pool eleve3 \
  --mode snapshot \
  --enabled 1 \
  --prune-backups 'keep-daily=7,keep-weekly=4,keep-monthly=6' \
  --notes-template '{{guestname}}'

pvesh get /cluster/backup
```

🧠 **Sélection par pool, jamais par liste de VM.** Une VM créée demain et ajoutée au pool
est sauvegardée automatiquement. Une liste figée, c'est la garantie qu'un jour une
machine importante ne sera pas dans la sauvegarde — et on ne s'en apercevra qu'au
moment de la restaurer.

### Voir la déduplication à l'œuvre 🎯

```bash
# Sauvegarde 1
vzdump N60 --storage pbs-lab --mode snapshot

# On modifie un peu la VM
ssh -J root@192.168.50.11 eleve@10.60.10.<ip> 'sudo apt install -y cowsay'

# Sauvegarde 2
vzdump N60 --storage pbs-lab --mode snapshot
```

🌐 Sur PBS : `Datastore → lab-store → Content`. Comparez la taille annoncée de chaque
sauvegarde avec l'espace réellement consommé.

```bash
# Sur PBS
proxmox-backup-manager datastore list --output-format json | jq
df -h /mnt/datastore/data
proxmox-backup-client snapshot list --repository eleve3@pbs@192.168.50.41:lab-store
```

---

## 7. Restaurer 🔄

C'est **la seule chose qui compte**. Une sauvegarde qu'on n'a jamais restaurée n'est pas
une sauvegarde, c'est une croyance.

### 7.1 Restauration complète

```bash
pvesm list pbs-lab
qm restore 365 pbs-lab:backup/vm/360/2026-08-02T02:30:00Z --storage local-lvm
qm start 365
```

🌐 `Storage pbs-lab → Backups → sélectionner → Restore`, en changeant le VMID.

### 7.2 Restauration d'un seul fichier ⭐

Le scénario réel : un utilisateur a supprimé un fichier. Restaurer 20 Go pour un
document de 3 Ko serait absurde.

🌐 `Storage pbs-lab → Backups → sélectionner → File Restore`

Un explorateur s'ouvre. Naviguez dans le système de fichiers de la sauvegarde,
téléchargez le fichier ou le dossier.

```bash
# En CLI, depuis n'importe quelle machine avec proxmox-backup-client
export PBS_REPOSITORY='eleve3@pbs@192.168.50.41:lab-store'
export PBS_PASSWORD='Formation2026!'

proxmox-backup-client snapshot list --ns eleve3
proxmox-backup-client list --ns eleve3 vm/360/2026-08-02T02:30:00Z
proxmox-backup-client restore --ns eleve3 \
  vm/360/2026-08-02T02:30:00Z drive-scsi0.img.fidx /tmp/restore/
```

### 7.3 Live-restore 🚀

La fonctionnalité la plus spectaculaire : la VM **démarre immédiatement**, et les blocs
sont récupérés depuis PBS **à la demande**, pendant qu'elle tourne.

🌐 `Restore → cocher « Start after restore » + « Live restore »`

```
   Restauration classique          Live restore
   ──────────────────────          ────────────
   [██████████] 20 Go              [▓░░░░░░░░░] démarre à 5 %
   ⏱ 8 minutes                     ⏱ 30 secondes
   puis démarrage                  les blocs arrivent en tâche de fond
```

🧠 **Cas d'usage** : 3 h du matin, le serveur de production est mort. On veut le service
de retour en 30 secondes, pas en 8 minutes. Les performances sont dégradées pendant la
récupération, mais le service est **rendu**.

### 7.4 Exercice obligatoire 🎯

```bash
# 1. Sauvegarder
vzdump N60 --storage pbs-lab --mode snapshot

# 2. Détruire pour de vrai
qm stop N60 && qm destroy N60 --purge
qm list | grep N60      # plus rien

# 3. Restaurer
qm restore N60 pbs-lab:backup/vm/N60/<timestamp> --storage local-lvm
qm start N60

# 4. Vérifier que la VM est fonctionnelle
qm agent N60 ping
ssh -J root@192.168.50.11 eleve@10.60.10.<ip> 'hostname; uptime'
```

✅ **Tant que vous n'avez pas fait ça, vous n'avez pas de sauvegarde.**

---

## 8. Chiffrement 🔐

PBS chiffre **côté client**, avant l'envoi. Le serveur ne voit que des chunks
inintelligibles.

```bash
# Sur le nœud PVE
proxmox-backup-client key create /etc/pve/priv/pbs-eleve3.enc --kdf none
proxmox-backup-client key show /etc/pve/priv/pbs-eleve3.enc
```

🌐 `Storage pbs-lab → Edit → Encryption Key`

🚨 **Perdez la clé, perdez les sauvegardes. Définitivement.** Il n'y a pas de porte
dérobée. Générez une **clé papier** :

```bash
proxmox-backup-client key paperkey /etc/pve/priv/pbs-eleve3.enc --output-format text
```

Imprimez-la, mettez-la dans un coffre. Ce n'est pas une plaisanterie : c'est la
procédure recommandée par Proxmox, et c'est ce qui distingue une sauvegarde chiffrée
d'une bombe à retardement.

🧠 **Pourquoi chiffrer ?** Parce que la sauvegarde part souvent hors site, chez un
prestataire, sur un NAS mal protégé. C'est une copie complète de toutes vos données,
au même endroit, souvent moins surveillée que la production. C'est **la** cible d'un
attaquant.

---

## 9. Maintenance du datastore 🧹

### Prune — supprimer les index anciens

```bash
proxmox-backup-manager prune-job create prune-eleve3 \
  --store lab-store --ns eleve3 --schedule 'daily' \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
proxmox-backup-manager prune-job list
```

### Garbage Collection — libérer réellement l'espace

```bash
proxmox-backup-manager garbage-collection start lab-store
proxmox-backup-manager garbage-collection list
```

🧠 **Prune ≠ GC.** *Prune* supprime les **index** des sauvegardes. Les **chunks**
restent sur le disque tant qu'ils sont référencés par au moins un index. C'est le
*garbage collector* qui balaie et supprime les chunks orphelins. Tant qu'il n'est pas
passé, l'espace n'est pas rendu — beaucoup d'administrateurs s'y font piéger.

Planifiez-le : `Datastore → Prune & GC → GC Schedule → daily`.

### Verify — vérifier l'intégrité

```bash
proxmox-backup-manager verify-job create verify-lab \
  --store lab-store --schedule 'sat 03:00' --ignore-verified true --outdated-after 30
```

🧠 Chaque chunk est vérifié contre son empreinte SHA-256. C'est ce qui détecte la
**corruption silencieuse** (bit rot) *avant* le jour où vous en aurez besoin. Une
sauvegarde non vérifiée est une sauvegarde dont on ne sait rien.

### Sync — la copie hors site

```bash
proxmox-backup-manager remote create pbs-distant \
  --host pbs2.exemple.nc --auth-id sync@pbs --password '...' --fingerprint '...'

proxmox-backup-manager sync-job create sync-hors-site \
  --store lab-store --remote pbs-distant --remote-store lab-store \
  --schedule 'daily 04:00'
```

```
   ┌─────────────┐  sync quotidien   ┌──────────────┐
   │  PBS local  │ ───────────────►  │ PBS distant  │
   │  (site A)   │  incrémental      │  (site B)    │
   └─────────────┘  dédupliqué       └──────────────┘
```

---

## 10. La règle 3-2-1 🛡️

```
   3  copies des données      (production + 2 sauvegardes)
   2  supports différents     (disque local + NAS/cloud)
   1  copie hors site         (autre bâtiment, autre ville)
```

Dans ce lab :

| | Réalisé | Comment |
|---|---|---|
| 3 copies | ✅ | VM + PBS + NFS |
| 2 supports | ⚠️ partiel | tout est sur le même matériel |
| 1 hors site | ❌ | c'est un lab — le job `sync` montre comment faire |

🪤 **Et la copie immuable ?** Un ransomware moderne cherche et chiffre les sauvegardes
avant de frapper la production. Réponses : un compte de sauvegarde en
`DatastoreBackup` (qui ne peut **pas** supprimer), un PBS distant qui **tire** les
données au lieu de les recevoir, et idéalement une bande ou un stockage WORM.

---

## ✅ Checklist de validation

- [ ] PBS est installé et accessible sur `https://192.168.50.41:8007`
- [ ] Un datastore `lab-store` existe sur un disque dédié
- [ ] Un namespace par élève existe
- [ ] Le stockage `pbs-lab` est actif sur les 6 nœuds
- [ ] Une sauvegarde manuelle réussit
- [ ] Un job planifié existe, **basé sur un pool**
- [ ] La deuxième sauvegarde d'une même VM consomme bien moins d'espace 🎯
- [ ] **J'ai détruit une VM et je l'ai restaurée entièrement** 🎯
- [ ] J'ai restauré un fichier isolé avec File Restore
- [ ] J'ai testé le live-restore
- [ ] Prune, GC et Verify sont planifiés
- [ ] Je sais expliquer la différence entre *prune* et *garbage collection*
- [ ] Je sais expliquer pourquoi l'agent QEMU compte pour la cohérence

---

## 🎁 Bonus

1. **Mesurer la déduplication** : sauvegardez trois VM Debian identiques dans le même
   datastore et comparez la somme des tailles annoncées avec `df -h`.
2. **`proxmox-backup-client` sur une machine quelconque** : sauvegardez le `/etc` d'une
   VM directement vers PBS, sans passer par Proxmox. PBS n'est pas réservé aux VM.
   ```bash
   proxmox-backup-client backup etc.pxar:/etc --repository eleve3@pbs@192.168.50.41:lab-store
   ```
3. **Restauration croisée** : restaurez une sauvegarde faite depuis `pve3` sur `pve5`.
   Que faut-il pour que ça marche ? (Indice : le stockage cible et le VNet.)
4. **Simuler la corruption** : modifiez un chunk à la main sur PBS
   (`/mnt/datastore/data/.chunks/...`), lancez un `verify`, et observez la détection.
   Puis restaurez le chunk. 😈
5. **Tape backup** : lisez la documentation de la sauvegarde sur bande. Pourquoi la
   bande revient-elle à la mode à l'ère du ransomware ?

➡️ Suite : [TP 19 — Pulse, une autre UI de supervision](19-pulse-monitoring.md)
