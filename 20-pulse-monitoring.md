# TP 20 — Pulse : une autre UI de supervision 📊

⏱️ **30 min** · Jour 4

Objectif : découvrir un outil de supervision tiers, complémentaire de l'interface
Proxmox, et pourquoi il faut un regard extérieur sur son cluster.

🔗 Projet : <https://github.com/rcourtman/Pulse>

---

## 1. Pourquoi un outil de plus ? 🧠

L'interface Proxmox sert à **agir**, moins à **surveiller** :

| Besoin | Interface PVE | Pulse |
|---|---|---|
| Vue unifiée PVE + PBS (+ Docker, K8s) | ❌ deux interfaces | ✅ un seul écran |
| Alertes configurables | limité aux notifications | ✅ seuils par ressource |
| « Quelle VM consomme le plus ? » | à chercher nœud par nœud | ✅ classement direct |
| État des sauvegardes en un coup d'œil | onglet par onglet | ✅ tableau global |
| Tourne **hors** du cluster | ❌ par définition | ✅ ⭐ |
| Historique long | RRD limité | selon la configuration |

🧠 Une supervision qui tourne *dans* le cluster qu'elle surveille meurt avec lui. Une
sonde externe, même modeste, vaut mieux qu'un tableau de bord qui s'éteint au moment où
vous en avez besoin.

---

## 2. Créer un compte de supervision 🔑

**En lecture seule.** Un outil de monitoring n'a jamais besoin d'écrire.

```bash
# Sur un nœud du cluster
pveum role add Monitoring -privs "VM.Audit Datastore.Audit Sys.Audit SDN.Audit Pool.Audit"
pveum user add pulse@pve --comment "Supervision Pulse (lecture seule)"
pveum aclmod / --users pulse@pve --roles Monitoring
pveum user token add pulse@pve mon --privsep 0
```

📌 Notez le token.

Et côté PBS :

```bash
# Sur la VM PBS de la salle (pve1)
proxmox-backup-manager user create pulse@pbs --password 'Formation2026!'
proxmox-backup-manager acl update /datastore Audit --auth-id pulse@pbs
proxmox-backup-manager user generate-token pulse@pbs mon
proxmox-backup-manager cert info | grep -i fingerprint
```

---

## 3. Installer Pulse 🚀

Trois méthodes.

### A — Conteneur LXC via le script communautaire ⭐ le plus rapide

```bash
# Sur pve1 — le stagiaire de pve1, ou le formateur
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pulse.sh)"
```

Le script crée un CT Debian, installe Pulse et affiche l'URL finale. Dans les
**options avancées**, fixez le CT ID à `902` (plan du TP 00 §5) ; par défaut il prend le
prochain libre, ce qui est acceptable aussi.

🪤 **Lisez un script avant de le passer à `bash`**, surtout en root, surtout depuis
Internet : `curl -fsSL <url> | less` d'abord.

### B — Docker, dans une VM

```bash
# Sur une VM Debian/Ubuntu de votre parc
curl -fsSL https://get.docker.com | sh

docker run -d --name pulse \
  -p 7655:7655 \
  -v pulse_data:/data \
  --restart unless-stopped \
  rcourtman/pulse:latest

docker logs -f pulse
```

### C — Manuellement

Suivez <https://github.com/rcourtman/Pulse/blob/main/docs/INSTALL.md>.

**Où l'installer ?** Idéalement **hors du cluster** : sur votre PC Ubuntu ou une machine
dédiée. Dans ce lab, un LXC sur un nœud fait l'affaire ; notez la contradiction.

Adresse : **fixée par le formateur** — notez-la, c'est votre `$PULSE`. L'UI écoute
sur le port **7655**.

---

## 4. Connecter le cluster et PBS 🔌

Ouvrez `http://$PULSE:7655`, puis l'assistant de configuration.

### Nœud Proxmox VE

| Champ | Valeur |
|---|---|
| Name | `cluster-formation` |
| Host | `https://172.30.30.151:8006` (pve1) |
| Token ID | `pulse@pve!mon` |
| Token Secret | *(le secret noté plus haut)* |
| Verify SSL | ❌ (certificat auto-signé) |

🧠 **Une seule adresse suffit pour le cluster** : l'API de n'importe quel nœud expose
`/cluster/resources`. Ajoutez un second nœud en point d'entrée de secours, sinon la
supervision tombe avec `pve1`.

### Serveur PBS

| Champ | Valeur |
|---|---|
| Name | `pbs-lab` |
| Host | `https://$PBS:8007` |
| Token | `pulse@pbs!mon` |
| Fingerprint | *(empreinte du certificat PBS)* |

---

## 5. Explorer 🔍

```
   ┌────────────────────────────────────────────────────────────┐
   │  PULSE                                    🟢 6 nœuds · 24 VM│
   ├────────────────────────────────────────────────────────────┤
   │  Dashboard   Guests   Storage   Backups   Alerts   Settings│
   ├────────────────────────────────────────────────────────────┤
   │                                                            │
   │   pve1  ████████░░  78 % CPU   ⚠️     pve4  ██░░░░░  22 %  │
   │   pve2  ███░░░░░░░  31 %             pve5  ████░░░  41 %   │
   │   pve3  █████░░░░░  52 %             pve6  ███░░░░  35 %   │
   │                                                            │
   │   ⚠️  pve1 · CPU > 75 % depuis 12 min                       │
   │   ⚠️  db01 · dernière sauvegarde il y a 9 jours             │
   │   🔴 vm-store (Ceph) · un OSD à 88 % — nearfull              │
   └────────────────────────────────────────────────────────────┘
```

À regarder en priorité :

| Vue | Ce qu'elle vous apprend |
|---|---|
| **Dashboard** | La santé globale, en un coup d'œil |
| **Guests** | Toutes les VM et CT du cluster, triables par consommation |
| **Storage** | Le remplissage de chaque stockage — **la panne n°1 en production** |
| **Ceph** | Santé du cluster, OSD, PG, pools |
| **Backups** | Quelles VM ne sont **pas** sauvegardées 🎯 |
| **Alerts** | Les seuils et l'historique des déclenchements |

🎯 **Regardez `local-lvm` et `vm-store` (Ceph)** dans la vue *Storage*. Un pool LVM-thin
au-delà de 95 % corrompt les VM ; un Ceph au-delà de 95 % arrête toutes les écritures.
Ces deux chiffres doivent alerter bien avant.

🎯 **Allez dans « Backups ».** Vous y trouverez probablement des machines dans aucun job
de sauvegarde : la question que l'interface native ne pose pas.

---

## 6. Configurer des alertes 🔔

`Settings → Alerts`

| Seuil | Valeur conseillée | Pourquoi |
|---|---|---|
| CPU nœud | > 85 % pendant 10 min | un pic passager n'est pas un incident |
| RAM nœud | > 90 % | au-delà, le swap dégrade tout |
| Stockage (`local-lvm`, Ceph) | > 85 % | ⭐ **le seuil le plus important** |
| Sauvegarde manquante | > 48 h | détecte les jobs cassés |
| VM arrêtée inopinément | immédiat | |
| Nœud injoignable | > 2 min | |

🧠 **Le stockage plein est la cause n°1 d'incident sur un hyperviseur.** Un LVM-thin à
100 % passe les volumes en lecture seule et corrompt les VM ; un datastore PBS plein fait
échouer les sauvegardes en silence. Alertez à 85 %, pas à 98 %.

Canaux de notification : e-mail, webhook, Gotify, ntfy, Telegram, Discord.

```bash
PULSE=172.30.30.___          # ⚠ l'adresse du conteneur Pulse
# Test rapide de webhook
curl -X POST http://$PULSE:7655/api/alerts/test
```

---

## 7. Les alternatives 🗺️

Pulse est léger et spécialisé. Le panorama :

| Outil | Type | Points forts | Limites |
|---|---|---|---|
| **Pulse** | dédié Proxmox | installation en 2 min, PVE+PBS unifiés | jeune, écosystème réduit |
| **Prometheus + Grafana** | métriques | ⭐ la référence, historique long, requêtes puissantes | à construire soi-même |
| **Zabbix** | supervision complète | agents, découverte auto, très complet | lourd à exploiter |
| **Checkmk** | supervision complète | excellent plugin Proxmox natif | version entreprise payante |
| **Netdata** | temps réel | granularité à la seconde, zéro configuration | rétention courte |
| **InfluxDB** *(natif PVE)* | métriques | ⭐ intégré à Proxmox, une ligne de conf | pas d'interface incluse |

### Le chemin natif : InfluxDB + Grafana

Proxmox exporte ses métriques nativement :

🌐 `Datacenter → Metric Server → Add → InfluxDB`

```bash
PULSE=172.30.30.___          # ⚠ l'adresse du conteneur Pulse
pvesh create /cluster/metrics/server/influx \
  --type influxdb --server $PULSE --port 8086 \
  --influxdbproto http --organization lab --bucket proxmox --token '<token>'
```

Puis un dashboard Grafana officiel (ID `10347` par exemple).

🧠 En production, c'est cette voie qu'on retiendrait : Prometheus/InfluxDB + Grafana +
Alertmanager. Pulse convient à un homelab, une PME, ou comme second regard à côté d'une
stack plus lourde.

---

## ✅ Checklist de validation

- [ ] Un compte `pulse@pve` en **lecture seule** existe, avec son token
- [ ] Pulse est installé et joignable
- [ ] Le cluster (6 nœuds) apparaît dans Pulse
- [ ] PBS est connecté et ses datastores remontent
- [ ] J'ai identifié au moins une VM sans sauvegarde récente 🎯
- [ ] Une alerte est configurée sur le remplissage du stockage
- [ ] Je sais expliquer pourquoi la supervision doit vivre **hors** du cluster
- [ ] Je connais au moins deux alternatives et sais quand les préférer

---

## 🎁 Bonus

1. **Provoquer une alerte** : remplissez un stockage à plus de 85 %
   (`fallocate -l 30G /srv/nfs/gros` sur votre poste) et vérifiez qu'elle part.
   Puis nettoyez.
2. **Webhook maison** : pointez les alertes vers un petit serveur HTTP
   (`python3 -m http.server`) et observez le JSON envoyé.
3. **Stack complète** : déployez Prometheus + Grafana avec le rôle Ansible du TP 13
   (bonus 1), branchez le metric server InfluxDB de Proxmox, et importez un dashboard
   communautaire. Comparez avec Pulse.
4. **La bonne question** : votre supervision est dans un LXC sur `pve3`. `pve3` prend
   feu. Que se passe-t-il ? Proposez une architecture qui règle le problème.

➡️ Suite : [TP 21 — Challenge final](21-challenge-final.md) 🏁
