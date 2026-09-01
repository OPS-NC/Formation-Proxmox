# TP 06 — Exploration complète de l'interface Proxmox 🧭

⏱️ **1 h 15** · Jour 2

Objectif : arrêter de chercher « où est ce réglage ». Faire le tour complet de
l'interface, comprendre la logique **Datacenter / Nœud / Guest**, et maîtriser les
outils d'organisation (pools, tags, permissions, tokens) dont on va dépendre pendant
trois jours.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pveum.html>

---

## 1. La logique des trois niveaux 🧠

Toute l'interface tient dans une question : **« à quel périmètre s'applique ce
réglage ? »**

```
   ┌─ DATACENTER ──────────────────────────────────────────────────────┐
   │  Ce qui est COMMUN à tout le cluster.                             │
   │  Répliqué par pmxcfs → identique sur les 6 nœuds.                 │
   │  Storage · Backup · Permissions · Pools · SDN · Firewall · HA     │
   │                                                                   │
   │   ┌─ NŒUD ───────────────────────────────────────────────────┐    │
   │   │  Ce qui est PROPRE à cette machine physique.             │    │
   │   │  Réseau · Disques · Certificats · Heure · Journaux       │    │
   │   │  Mises à jour · Shell · Firewall du nœud                 │    │
   │   │                                                          │    │
   │   │   ┌─ GUEST (VM / CT) ──────────────────────────────┐     │    │
   │   │   │  Ce qui est PROPRE à cette machine virtuelle.  │     │    │
   │   │   │  Hardware · Options · Snapshots · Backup       │     │    │
   │   │   │  Console · Firewall · Permissions              │     │    │
   │   │   └────────────────────────────────────────────────┘     │    │
   │   └──────────────────────────────────────────────────────────┘    │
   └───────────────────────────────────────────────────────────────────┘
```

**Le réflexe** : si c'est physique → nœud. Si c'est logique ou partagé → datacenter.
Si c'est spécifique à une machine → guest.

---

## 2. La barre du haut et l'arbre de gauche 🌳

### Le sélecteur de vue (en haut de l'arbre)

| Vue | Affiche |
|---|---|
| **Server View** | par nœud — la vue par défaut, physique |
| **Folder View** | par type — toutes les VM ensemble, tous les CT ensemble |
| **Pool View** | par pool — ⭐ celle qu'on utilisera en cluster |
| **Tag View** | par tag — regroupe par étiquette |

🌐 **Testez les quatre maintenant.** En cluster à 6 élèves, la *Pool View* sera la
seule utilisable.

### La barre du haut

| Élément | Rôle |
|---|---|
| Recherche 🔍 | Filtre instantané sur tous les objets du cluster |
| Documentation | Ouvre la doc **locale**, hors ligne, à la bonne page |
| Create VM / Create CT | Toujours accessibles |
| Menu utilisateur | Langue de l'interface, thème, TFA, déconnexion |

### Le bandeau du bas : les tâches ⭐

C'est le panneau le plus utile et le plus ignoré.

| Onglet | Contenu |
|---|---|
| **Tasks** | Toutes les opérations, en cours et passées, avec leur log |
| **Cluster log** | Les événements du cluster |

🌐 **Double-cliquez sur une tâche** → vous obtenez sa sortie complète. C'est **là** que
se trouve la vraie erreur quand une action échoue avec un message vague.

```bash
# La même chose en CLI
pvesh get /nodes/pveN/tasks --limit 20
pvesh get /cluster/tasks
```

---

## 3. Datacenter, onglet par onglet 🏢

| Onglet | À quoi ça sert | Quand on y touche |
|---|---|---|
| **Summary** | Vue globale : nœuds, ressources, quorum | quotidien |
| **Cluster** | Créer / rejoindre un cluster | TP 16 |
| **Ceph** | Stockage distribué | ⭐ TP 18 |
| **Options** | Réglages par défaut du datacenter ⬇ | maintenant |
| **Storage** | Déclaration des stockages | TP 02, 14 |
| **Backup** | Jobs de sauvegarde planifiés | TP 15 |
| **Replication** | Réplication de stockage — **ZFS uniquement, non utilisé ici** | — |
| **Permissions** | Users, Groups, Pools, Roles, API Tokens, Realms | maintenant |
| **HA** | Haute disponibilité | TP 19 |
| **SDN** | Zones, VNets, Subnets, IPAM, DNS, Fabrics | TP 08, 17 |
| **Firewall** | Règles, groupes, alias, IPSets | TP 09 |
| **Metric Server** | Export vers InfluxDB / Graphite | TP 20 (bonus) |
| **Notifications** | Cibles et matchers de notification | ⬇ |
| **Support** | État de l'abonnement | jamais |

### 3.1 Options du datacenter

🌐 `Datacenter → Options`. Passez en revue :

| Option | Effet | Recommandation lab |
|---|---|---|
| Keyboard Layout | Clavier des consoles noVNC | `fr` |
| Console Viewer | noVNC / SPICE / xterm.js par défaut | `Default (noVNC)` |
| Email from address | Expéditeur des notifications | `pve@lab.local` |
| MAC address prefix | Préfixe MAC des VM | laisser |
| Migration Settings | Réseau et type de migration | TP 19 |
| **Next Free VMID Range** | Borne l'attribution automatique | ⭐ `N00`–`N99` |
| Cluster Resource Scheduling | Algorithme de placement HA | TP 19 |
| Tag Style Override | Couleur des tags ⬇ | ⭐ |
| U2F / WebAuthn | Second facteur | bonus |

🎯 **Faites-le maintenant** : réglez *Next Free VMID Range* sur votre plage. L'interface
proposera automatiquement le bon VMID et vous ne marcherez plus sur les plates-bandes
des autres au jour 4.

### 3.2 Notifications

Depuis PVE 8.1, les notifications passent par un système de **cibles** (targets) et de
**matchers** (qui filtre quoi part où).

🌐 `Datacenter → Notifications`

```
   Événement (backup échoué, disque plein, tâche en erreur…)
        │
        ▼
   ┌──────────┐   correspond au filtre ?   ┌──────────────┐
   │ MATCHER  │ ─────────────────────────► │    TARGET    │
   │ severity │                            │ mail / gotify│
   │ type     │                            │ smtp / webhook│
   └──────────┘                            └──────────────┘
```

Créez une cible **Gotify** ou **SMTP** si le formateur en fournit une, sinon
observez simplement la cible `mail-to-root` par défaut et son matcher.

```bash
pvesh get /cluster/notifications/endpoints/sendmail
pvesh get /cluster/notifications/matchers
```

---

## 4. Les pools de ressources 📁

Un **pool** regroupe VM, CT et stockages. Deux usages :
1. **Organiser** l'affichage (Pool View),
2. **Déléguer des droits** d'un seul geste.

```bash
N=3
pvesh create /pools --poolid eleve$N --comment "Ressources de l'eleve $N" 2>/dev/null
pvesh get /pools
```

Ajoutez-y toutes vos machines :

```bash
N=3     # ⚠ VOTRE numéro d'élève
for id in ${N}01 ${N}02 ${N}11 ${N}12; do
  pvesh set /pools/eleve$N --vms $id 2>/dev/null
done
pvesh get /pools/eleve$N
```

🌐 Basculez en **Pool View**. Vos machines sont regroupées.

🧠 **La vraie force du pool** : `pveum aclmod /pool/eleve3 --users stagiaire@pve --roles
PVEVMUser` donne à un utilisateur le droit d'utiliser *exactement* ces machines, et rien
d'autre. Pas besoin de lister VM par VM, et les nouvelles VM ajoutées au pool héritent
automatiquement des droits.

---

## 5. Les tags 🏷️

Un tag est une étiquette libre posée sur un guest. Contrairement au pool, un guest peut
en porter **plusieurs**.

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm set ${N}01 --tags "debian,interne,prod"
qm set ${N}02 --tags "windows,interne,rdp"
pct set ${N}11 --tags "alpine,dmz,web"
pct set ${N}12 --tags "rocky,dmz,web"
```

🌐 Basculez en **Tag View**, puis filtrez avec la barre de recherche.

### Personnaliser les couleurs

🌐 `Datacenter → Options → Tag Style Override → Edit`

```
prod:FF4444:FFFFFF;dmz:FF8800:000000;interne:0088FF:FFFFFF;web:22AA22:FFFFFF
```

Format : `tag:couleurFond:couleurTexte;` séparés par `;`.

Réglez aussi `Tag Style Override → Ordering: Alphabetical` et
`Case-sensitive: no` pour éviter `Prod` et `prod` en double.

🧠 **Pourquoi les tags nous intéressent tant ?** Parce qu'au **TP 13**, Ansible va
construire son inventaire **à partir de ces tags** : le groupe `web` sera peuplé
automatiquement par toutes les machines taguées `web`. Un tag posé ici = un rôle
Ansible appliqué là-bas. Soignez-les.

```bash
# Tous les guests portant un tag donné
pvesh get /cluster/resources --type vm --output-format json \
  | jq -r '.[] | select(.tags != null and (.tags | test("web"))) | "\(.vmid)\t\(.name)\t\(.tags)"'
```

---

## 6. Utilisateurs, rôles et permissions 🔐

### 6.1 Le modèle

```
   ┌──────────┐      ┌──────────┐      ┌──────────────────────┐
   │   USER   │      │  GROUP   │      │        PATH          │
   │ eleve@pve├─────►│ stagiaires├────►│ /pool/eleve3         │
   └──────────┘      └────┬─────┘      │ /vms/301             │
                          │            │ /storage/local       │
                          │            │ /sdn/zones/zint      │
                          ▼            │ /  (racine)          │
                     ┌─────────┐       └──────────────────────┘
                     │  ROLE   │
                     │PVEVMUser│  = un ensemble de PRIVILÈGES
                     └─────────┘
```

Une **ACL** = (chemin, utilisateur ou groupe, rôle, propagation).

### 6.2 Les realms (domaines d'authentification)

| Realm | Usage |
|---|---|
| `pam` | Comptes Unix du nœud — `root@pam` |
| `pve` | Base interne Proxmox — ⭐ pour les comptes applicatifs |
| `ldap` / `ad` | Annuaire d'entreprise |
| `openid` | SSO (Keycloak, Authentik, Entra ID…) |

### 6.3 Les rôles intégrés

```bash
pveum role list
```

| Rôle | Donne |
|---|---|
| `Administrator` | tout |
| `PVEAdmin` | tout sauf la modification des permissions |
| `PVEAuditor` | lecture seule sur tout ⭐ pour la supervision |
| `PVEVMAdmin` | administration complète des VM |
| `PVEVMUser` | démarrer/arrêter/console, sans modifier le matériel |
| `PVEDatastoreUser` | allouer de l'espace |
| `PVESDNUser` | utiliser les VNets d'une zone |
| `NoAccess` | bloque explicitement ⭐ pour faire une exception |

### 6.4 Exercice : créer un compte « stagiaire » 🎯

```bash
N=3
pveum group add stagiaires --comment "Comptes de TP en lecture-execution"
pveum user add stagiaire$N@pve --password 'Stagiaire2026!' --groups stagiaires
pveum aclmod /pool/eleve$N --groups stagiaires --roles PVEVMUser
pveum acl list
```

Testez : déconnectez-vous, reconnectez-vous en `stagiaire3@pve` (realm
*Proxmox VE authentication server*).

✅ Ce que vous devez constater :
- Vous voyez **uniquement** les machines de votre pool,
- Vous pouvez les démarrer, les arrêter, ouvrir la console,
- Le bouton **Create VM** est grisé,
- L'onglet **Hardware** est en lecture seule,
- `Datacenter → Permissions` est inaccessible.

🧠 **C'est ça, la délégation propre.** En production, on ne donne jamais `root@pam` à
un prestataire : on crée un pool, un groupe, une ACL.

### 6.5 Un rôle sur mesure

```bash
pveum role add SuperviseurLab -privs "VM.Audit Datastore.Audit Sys.Audit SDN.Audit Pool.Audit"
pveum user add monitoring@pve --comment "Compte lecture seule pour Pulse/Zabbix"
pveum aclmod / --users monitoring@pve --roles SuperviseurLab
```

On s'en resservira au **TP 20** pour Pulse.

---

## 7. Les tokens d'API 🔑

Un token est un secret rattaché à un utilisateur, **révocable indépendamment** et
utilisable sans mot de passe. C'est ce qu'on donne à un script, jamais un mot de passe.

### 7.1 Le compte de service Terraform

```bash
pveum role add TerraformProv -privs "\
Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Pool.Audit \
SDN.Allocate SDN.Audit SDN.Use \
Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit \
VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.Migrate VM.Monitor VM.PowerMgmt \
User.Modify"

pveum user add terraform@pve --comment "Compte de service Terraform"
pveum aclmod / --users terraform@pve --roles TerraformProv
pveum user token add terraform@pve tf --privsep 0
```

La commande affiche **une seule fois** :

```
┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
├──────────────┼──────────────────────────────────────┤
│ full-tokenid │ terraform@pve!tf                     │
│ value        │ 12345678-90ab-cdef-1234-567890abcdef │
└──────────────┴──────────────────────────────────────┘
```

🧠 **`--privsep 0`** signifie « le token hérite de tous les droits de son utilisateur ».
Avec `--privsep 1` (le défaut), il faut poser des ACL **sur le token lui-même** — plus
sûr, plus verbeux. Pour un lab : `0`. En production : `1`, avec le minimum de droits.

### 7.2 Le compte de service Ansible

Ansible n'a besoin que de **lire** l'inventaire :

```bash
pveum user add ansible@pve --comment "Inventaire dynamique Ansible"
pveum aclmod / --users ansible@pve --roles PVEAuditor
pveum user token add ansible@pve inv --privsep 0
```

### 7.3 Stocker les secrets sur votre PC

```bash
# 💻 Sur votre PC Ubuntu
mkdir -p ~/.config/pve && chmod 700 ~/.config/pve
cat > ~/.config/pve/token.env <<'EOF'
export PVE_HOST="172.30.30.153"
export PVE_NODE="pve3"
export PVE_ENDPOINT="https://172.30.30.153:8006/"
export PVE_API_TOKEN="terraform@pve!tf=12345678-90ab-cdef-1234-567890abcdef"
export PVE_ANSIBLE_TOKEN_ID="ansible@pve!inv"
export PVE_ANSIBLE_TOKEN_SECRET="abcdef00-1111-2222-3333-444455556666"
EOF
chmod 600 ~/.config/pve/token.env
```

### 7.4 Tester

```bash
source ~/.config/pve/token.env

curl -sk -H "Authorization: PVEAPIToken=$PVE_API_TOKEN" \
  "$PVE_ENDPOINT/api2/json/nodes" | jq -r '.data[] | "\(.node)\t\(.status)"'

curl -sk -H "Authorization: PVEAPIToken=$PVE_API_TOKEN" \
  "$PVE_ENDPOINT/api2/json/cluster/resources?type=vm" \
  | jq -r '.data[] | "\(.vmid)\t\(.name)\t\(.tags // "-")"'
```

🪤 Le format d'en-tête est **`PVEAPIToken=user@realm!tokenid=secret`**.
Un espace, un `:` au lieu du `=`, ou un `!` oublié → `401 authentication failure`.

### 7.5 Révoquer

```bash
pveum user token list terraform@pve
pveum user token remove terraform@pve tf     # ne le faites PAS maintenant
```

---

## 8. Le nœud, onglet par onglet 🖥️

| Onglet | Contenu |
|---|---|
| **Summary** | CPU, RAM, I/O, uptime, version. Graphiques sur 1 h → 1 an |
| **Notes** | Markdown libre ⭐ documentez votre nœud ici |
| **Shell** | Console root dans le navigateur (xterm.js) |
| **System → Network** | Bridges, bonds, VLAN. Bouton **Apply Configuration** |
| **System → Certificates** | Certificat auto-signé, ACME / Let's Encrypt |
| **System → DNS / Hosts / Time** | ⭐ le fichier `hosts` est éditable ici |
| **System → Syslog** | `journalctl` en direct |
| **Updates → Repositories** | Gestion graphique des dépôts (TP 01) |
| **Firewall** | Règles et options **du nœud** |
| **Disks** | Disques physiques, SMART, LVM, LVM-Thin, Directory |
| **Disks → SMART** | ⭐ l'état de santé de vos disques, à surveiller |
| **Replication** | Jobs de réplication (ZFS uniquement) |
| **Subscription** | État de l'abonnement |

🎯 **Exercice** : dans `Notes`, écrivez la fiche de votre nœud en markdown.

```markdown
# pve3 — élève 3
- IP : 172.30.30.153
- Plage VMID : 300-399
- Subnets SDN : 10.3.10.0/24 (int), 10.3.20.0/24 (dmz)
- Disques : sda (système), sdb (données)
- Contact : eleve3@formation.local
```

🧠 En production, ces notes sont ce que votre collègue lira à 3 h du matin.
Ne les négligez pas.

---

## 9. Un guest, onglet par onglet 📋

| Onglet | Contenu |
|---|---|
| **Summary** | État, IP (via l'agent), graphiques, notes, tags |
| **Console** | noVNC / SPICE / xterm.js |
| **Hardware** | Disques, CPU, RAM, cartes réseau, TPM, PCI |
| **Cloud-Init** | Uniquement si un disque cloud-init est présent (TP 10) |
| **Options** | Boot order, démarrage auto, agent, hotplug, protection ⬇ |
| **Task History** | Toutes les opérations sur cette VM |
| **Monitor** | Console QEMU (`info block`, `info network`…) |
| **Backup** | Sauvegardes de cette VM |
| **Replication** | Réplication ZFS |
| **Snapshots** | Instantanés |
| **Firewall** | Règles propres à cette VM |
| **Permissions** | ACL sur cette VM |

### L'option qui sauve : `Protection`

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm set ${N}01 --protection 1
qm destroy ${N}01           # → refusé
qm set ${N}01 --protection 0
```

🧠 À activer sur toute VM de production. Empêche la suppression et l'effacement du
disque, même en `root`. Coût : zéro. Bénéfice : énorme.

### Les autres options utiles

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm set ${N}01 --onboot 1 --startup order=2,up=30,down=60
qm set ${N}01 --hotplug disk,network,usb,memory,cpu
qm set ${N}01 --description "Serveur applicatif — contact: eleve3@formation.local"
```

`startup order=2,up=30` : démarre en deuxième position, puis attend 30 s avant de lancer
le suivant. Indispensable pour respecter un ordre base → application → frontal.

---

## 10. Le Monitor QEMU 🔬

Peu connu, très utile pour le diagnostic.

🌐 `VM → Monitor`, puis :

```
info block
info network
info status
info balloon
info snapshots
```

Équivalent CLI :

```bash
N=3     # ⚠ VOTRE numéro d'élève
qm monitor ${N}01
# puis les mêmes commandes ; « quit » pour sortir
```

---

## ✅ Checklist de validation

- [ ] Je sais dire, pour un réglage donné, s'il est *datacenter*, *nœud* ou *guest*
- [ ] J'ai testé les 4 vues de l'arbre (Server / Folder / Pool / Tag)
- [ ] `Next Free VMID Range` est réglé sur ma plage
- [ ] Mes 4 machines sont dans le pool `eleveN`
- [ ] Mes machines portent des tags cohérents (`interne`, `dmz`, `web`…)
- [ ] Les couleurs de tags sont personnalisées
- [ ] Un compte `stagiaireN@pve` existe et ne voit que mon pool
- [ ] Les tokens `terraform@pve!tf` et `ansible@pve!inv` sont créés et testés au `curl`
- [ ] `~/.config/pve/token.env` existe sur mon PC, en `chmod 600`
- [ ] La fiche de mon nœud est écrite dans `Notes`
- [ ] Je sais où lire le log complet d'une tâche qui a échoué

---

## 🎁 Bonus

1. **Second facteur** : activez TOTP sur `eleve@pve`
   (`Datacenter → Permissions → Two Factor → Add → TOTP`). Scannez avec votre
   téléphone. Puis reconnectez-vous.
2. **Realm OpenID** : si le formateur fournit un Keycloak, configurez le SSO.
3. **Explorer l'API par l'interface** : ouvrez les outils de développement (F12 →
   Réseau), cliquez sur « Start » d'une VM, et repérez l'appel
   `POST /api2/extjs/nodes/pveN/qemu/N01/status/start`. Vous venez de découvrir
   comment automatiser n'importe quelle action que vous ne savez faire qu'en cliquant.
4. **Documentation embarquée** : cliquez sur le bouton *Documentation* depuis
   `Datacenter → SDN`. Vous atterrissez directement au bon chapitre, **hors ligne**.

➡️ Suite : [TP 07 — Réseau « à l'ancienne » : vmbr1 natté](07-reseau-classique-vmbr1-nat.md)
