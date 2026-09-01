# TP 21 — Challenge final 🏁

⏱️ **45 min** · Jour 4

Tout ce que vous avez appris, en une seule mission. Pas de pas-à-pas : un cahier des
charges, et vous.

---

## 🎬 Le scénario

> **Cabinet Karembeu & Associés** — 45 salariés, Nouméa.
> Vous venez de reprendre l'infrastructure. Le prestataire précédent est parti sans
> documentation. La direction veut :
>
> 1. une application web accessible aux clients ;
> 2. sa base de données **inaccessible depuis Internet** ;
> 3. un poste Windows d'administration, joignable en RDP par le service informatique
>    **uniquement** ;
> 4. le **service web** doit survivre à la panne d'un serveur ;
> 5. tout doit être sauvegardé et **la restauration doit être prouvée** ;
> 6. l'infrastructure doit être reproductible : « si un incendie détruit la salle, on
>    doit pouvoir tout remonter depuis Git ».

Vous avez le cluster, le SDN EVPN, PBS, Terraform et Ansible. Au travail.

---

## 📋 Cahier des charges

### Réseau

| Zone | Subnet | Accès Internet | Contenu |
|---|---|---|---|
| `vprod` | `10.60.10.0/24` | ✅ sortant | serveur applicatif |
| `vpub` | `10.60.20.0/24` | ✅ sortant (80/443/53 seulement) | frontal web |
| `vdb` | `10.60.30.0/24` | ❌ **aucun** | base de données |

Matrice de flux attendue :

```
                    ☁ Internet
                         ▲
              80/443/53  │
   ┌─────────────────────┴──────────────────────┐
   │                                            │
   │   vpub  ──── 8080 ────►  vprod             │
   │    ▲                       │               │
   │    │                       │ 5432          │
   │    │ (rien en retour)      ▼               │
   │    ✖ ◄──────────────    vdb                │
   │                          (aucun Internet)  │
   └────────────────────────────────────────────┘
```

| De ↓ / Vers → | vpub | vprod | vdb | Internet |
|---|:---:|:---:|:---:|:---:|
| **vpub** | 80/443 | **8080** | ❌ | 80/443/53 |
| **vprod** | ❌ | libre | **5432** | 80/443/53 |
| **vdb** | ❌ | ❌ | libre | ❌ |

### Machines

| Nom | OS | Zone | Rôle | Contrainte |
|---|---|---|---|---|
| `front-eN` | Ubuntu 26.04 | `vpub` | nginx en reverse-proxy vers `app` | déployé par Terraform |
| `app-eN` | Debian 13 | `vprod` | une appli qui écoute en 8080 | déployé par Terraform |
| `data-eN` | Rocky Linux 10 | `vdb` | PostgreSQL | déployé par Terraform |
| `cache-eN` | Alpine (LXC) | `vprod` | Redis ou nginx cache | déployé par Terraform |
| — | — | — | Stockage | `front` et `app` sur **Ceph** · `data` sur **`local-lvm`** — ⚠️ voir ci-dessous |
| `adm-eN` | Windows Server 2025 | `vprod` | poste d'administration | RDP depuis `vprod` **seulement** |

> 🎯 **`data` sur `local-lvm` : ce n'est pas un oubli, c'est l'arbitrage à défendre.**
>
> Un disque local n'est pas répliqué : si son nœud tombe, `data` **ne redémarre pas
> ailleurs** — la HA n'a nulle part où la relancer. La base est donc protégée par la
> **sauvegarde** (épreuve 6), pas par la haute disponibilité.
>
> C'est un choix courant et défendable : une base de données a ses propres mécanismes
> de réplication, et beaucoup d'équipes préfèrent un disque local rapide + une
> réplication applicative plutôt qu'un stockage distribué sous la base. Ce qui n'est
> **pas** défendable, c'est de ne pas le savoir.
>
> **Le formateur vous demandera** : « quel est votre RPO et votre RTO sur `data` ? »
> La bonne réponse cite la fréquence du job de sauvegarde et le temps de restauration
> mesuré à l'épreuve 6 — pas « c'est en HA ».

### Exigences transverses

- [ ] Toutes les machines Linux sont configurées par **Ansible**, groupées par **tags**
- [ ] Un `ansible-playbook site.yml` répété affiche **`changed=0`**
- [ ] Les disques de `front` et `app` sont sur **`vm-store` (Ceph)**
- [ ] `front` et `app` sont en **HA**, avec une règle d'**anti-affinité**
- [ ] `data` n'est **pas** en HA, et je sais dire pourquoi (RPO/RTO à l'appui)
- [ ] Un job de **sauvegarde par pool** tourne, avec une rétention définie
- [ ] Le **firewall** applique exactement la matrice ci-dessus, en *default deny*
- [ ] Le dépôt Git contient tout le code : `terraform apply` + `ansible-playbook`
      doivent reconstruire l'ensemble depuis zéro

---

## 🧪 Les épreuves de recette

Le formateur passera sur chaque poste et exécutera ces tests. **Préparez-les.**

### Épreuve 1 — Chaîne applicative ✅

```bash
# Depuis un poste de vprod
curl -sI http://<ip-front>/            # → 200
curl -s  http://<ip-front>/ | head     # → la page servie par app, via le proxy
```

### Épreuve 2 — Cloisonnement 🔒

```bash
# Depuis front (vpub)
nc -zvw2 <ip-data> 5432      # → ❌ timeout
nc -zvw2 <ip-adm> 3389       # → ❌ timeout
ping -c2 <ip-app>            # → ❌ (seul le 8080 est ouvert)
nc -zvw2 <ip-app> 8080       # → ✅

# Depuis data (vdb)
ping -c2 1.1.1.1             # → ❌ aucun Internet
ping -c2 10.60.30.1          # → ✅ sa gateway
nc -zvw2 <ip-front> 80       # → ❌
```

### Épreuve 3 — Résilience réseau 🌐

```bash
ping <ip-app>                          # en continu
qm migrate <vmid-app> pve5 --online    # dans un autre terminal
# → 0 ou 1 paquet perdu
```

### Épreuve 4 — MTU 📏

```bash
# depuis n'importe quelle VM
ping -M do -s 1422 -c2 1.1.1.1      # → ✅
sudo apt update && sudo apt install -y cowsay   # → ✅ (le vrai test)
```

### Épreuve 5 — Haute disponibilité et Ceph 🏥

Le formateur coupe l'alimentation d'un nœud hébergeant `front` ou `app`.

→ La VM redémarre ailleurs en moins de **3 minutes**, et `front` répond de nouveau.
→ `ceph -s` passe en `HEALTH_WARN` puis se reconstruit seul jusqu'à `HEALTH_OK`.
→ Aucune donnée perdue.

**Question piège du formateur** : « et si j'avais coupé le nœud de `data` ? »
Réponse attendue : elle ne redémarre pas ailleurs — son disque est sur `local-lvm`,
donc local à ce nœud. On la restaure depuis PBS (épreuve 6), et on assume le RPO
correspondant. Répondre « elle bascule aussi » est **la** faute à ne pas commettre.

```bash
ceph -s
ceph osd tree
ha-manager status
```

### Épreuve 6 — Restauration 💾

```bash
qm stop <vmid-app> && qm destroy <vmid-app> --purge
# ... restaurez depuis PBS ...
curl -sI http://<ip-front>/     # → 200, la chaîne complète refonctionne
```

### Épreuve 7 — Reproductibilité 🔁

```bash
terraform destroy -target=proxmox_virtual_environment_vm.cache
terraform apply
ansible-playbook site.yml
# → la machine est de retour, configurée, sans intervention manuelle
```

### Épreuve 8 — Documentation 📖

Le formateur ouvre votre `README.md` de rendu. Il doit y trouver, en moins de deux
minutes :
- le schéma réseau,
- la matrice de flux,
- le plan d'adressage et de VMID,
- la procédure de restauration,
- ce que vous auriez fait différemment avec un vrai budget.

---

## 📦 Le livrable

Un dépôt Git, poussé ou remis au formateur :

```
rendu-eleveN/
├── README.md                ← ⭐ le document le plus important
├── docs/
│   ├── schema-reseau.md     schéma ASCII ou image
│   ├── matrice-flux.md      le tableau, commenté
│   ├── plan-adressage.md    IP, VMID, tags
│   └── restauration.md      la procédure, pas à pas
├── terraform/
│   ├── *.tf
│   └── terraform.tfvars.example   (⚠️ jamais le vrai)
├── ansible/
│   ├── inventory/proxmox.yml
│   ├── roles/{common,front,app,data}/
│   └── site.yml
├── firewall/
│   ├── cluster.fw
│   ├── vpub.fw / vprod.fw / vdb.fw
├── sdn/
│   ├── controllers.cfg / zones.cfg / vnets.cfg / subnets.cfg
└── ceph/
    ├── ceph.conf
    ├── ceph-s.txt          sortie de « ceph -s »
    └── ceph-osd-tree.txt   sortie de « ceph osd tree »
```

```bash
# Extraire la configuration réelle pour le rendu
ssh root@172.30.30.15N 'tar cz /etc/pve/sdn /etc/pve/firewall' \
  | tar xz -C rendu-eleveN/ --strip-components=2

mkdir -p rendu-eleveN/ceph
ssh root@172.30.30.15N 'cat /etc/pve/ceph.conf'  > rendu-eleveN/ceph/ceph.conf
ssh root@172.30.30.15N 'ceph -s'                 > rendu-eleveN/ceph/ceph-s.txt
ssh root@172.30.30.15N 'ceph osd tree'           > rendu-eleveN/ceph/ceph-osd-tree.txt
ssh root@172.30.30.15N 'lvs; vgs'                > rendu-eleveN/docs/lvm.txt
```

🪤 **Vérifiez qu'aucun secret ne part dans le dépôt** :

```bash
grep -rniE 'password|secret|token|BEGIN .*PRIVATE KEY' rendu-eleveN/ \
  --exclude-dir=.git | grep -v example
```

---

## 🏆 Barème

| Critère | Points |
|---|---|
| La chaîne applicative fonctionne de bout en bout | 20 |
| Le cloisonnement réseau est exact (épreuve 2) | **25** |
| Migration à chaud sans perte | 10 |
| HA fonctionnelle avec anti-affinité | 15 |
| Restauration prouvée depuis PBS | **15** |
| Ceph en `HEALTH_OK`, 6 OSD, disques applicatifs dessus | 10 |
| Infrastructure reproductible (Terraform + Ansible) | 10 |
| Documentation lisible et honnête | 5 |
| **Total** | **110** |

**Bonus** (jusqu'à +15) :
- 🎁 +5 — Un troisième rôle Ansible pertinent (supervision, journalisation, sauvegarde)
- 🎁 +5 — Publication du frontal vers le LAN salle (DNAT ou reverse-proxy) documentée
- 🎁 +5 — Une CI qui valide `terraform validate` et `ansible-lint`

**Malus** :
- 🚫 −10 — Un secret en clair dans le dépôt
- 🚫 −10 — Un test de restauration jamais effectué
- 🚫 −5 — `changed != 0` au second passage d'Ansible

---

## 💡 Conseils

1. **Commencez par le schéma et la matrice de flux.** Écrire les règles avant d'avoir
   décidé de la politique, c'est se condamner à bricoler.
0. **Avant tout : `ceph -s` doit être vert.** Si Ceph est dégradé, la HA ne servira à
   rien et vous perdrez des points sur deux épreuves.
2. **Faites tourner l'ensemble avant d'optimiser.** Un truc moche qui marche vaut mieux
   qu'un truc élégant à moitié fini.
3. **`git commit` souvent.** Vous allez casser quelque chose. C'est certain.
4. **Testez le firewall en dernier**, une fois que tout fonctionne. Sinon vous
   passerez votre temps à vous demander si le problème vient du réseau ou des règles.
5. **La documentation, ce n'est pas la dernière tâche** : écrivez-la au fur et à mesure,
   sinon vous n'aurez plus le temps.
6. **Bloquez 10 minutes pour l'épreuve de restauration.** C'est 15 points, et c'est
   la seule preuve qui compte vraiment.

---

## 🎓 Ce que vous emportez

En quatre jours, vous êtes passés d'une machine nue à :

```
   ┌───────────────────────────────────────────────────────────────┐
   │  Cluster Proxmox VE 9 · 6 nœuds · quorum · HA                 │
   │  SDN EVPN/VXLAN · gateway anycast · exit nodes · SNAT         │
   │  Firewall nftables segmenté · default deny · journalisé       │
   │  Stockage : local-lvm · NFS · CEPH ×3 copies sans SPOF        │
   │  Sauvegarde PBS dédupliquée, chiffrée, vérifiée, restaurée    │
   │  Infrastructure as Code : Terraform + Ansible + Git           │
   │  Supervision externe                                          │
   └───────────────────────────────────────────────────────────────┘
```

Mais surtout, vous avez acquis quelques réflexes qui valent plus que les commandes :

- 🧠 **Lire un message d'erreur en entier** avant de chercher sur Internet.
- 🧠 **Faire un schéma avant de configurer.** Toujours.
- 🧠 **Une sauvegarde non restaurée n'existe pas.**
- 🧠 **Fermer par défaut**, ouvrir par exception, documenter chaque exception.
- 🧠 **Savoir énoncer les limites de son architecture** vaut mieux que de prétendre
  qu'elle est parfaite.
- 🧠 **Si vous l'avez fait deux fois à la main, scriptez-le.**
- 🧠 **Anticipez le partitionnement.** Cinq secondes sur `maxvz` à l'installation ont
  économisé quarante minutes de chirurgie LVM au jour 4.
- 🧠 **Réplication ≠ sauvegarde.** Ceph copie fidèlement vos suppressions, en trois
  exemplaires.

---

## 📚 Pour continuer

| Sujet | Où aller |
|---|---|
| **Ceph en production** | Dimensionnement réseau, erasure coding, CRUSH avancée, RGW/S3 |
| **Proxmox Datacenter Manager** | Piloter plusieurs clusters depuis un point unique |
| **SDN Fabrics** | OpenFabric / OSPF / BGP, pour du multi-segment et du multi-site |
| **Certification** | *Proxmox VE Advanced* — <https://www.proxmox.com/en/training> |
| **Forum** | <https://forum.proxmox.com/> — la meilleure ressource, très active |
| **Code source** | <https://git.proxmox.com/> — tout est libre, allez lire |

---

**Bravo, et merci pour ces quatre jours. 🎉**

Une dernière chose : la documentation officielle est excellente, complète, et
disponible **hors ligne dans votre interface** (bouton *Documentation*). La grande
majorité des questions que vous vous poserez y ont déjà une réponse. Prenez le réflexe
d'y aller en premier.

📖 <https://pve.proxmox.com/pve-docs/>

⬅️ Retour au [sommaire](README.md)
