# TP 05 — Conteneurs LXC : Alpine et Rocky Linux 📦

⏱️ **1 h 15** · Jour 2

Objectif : créer des conteneurs LXC, comprendre en quoi ils diffèrent d'une VM et d'un
conteneur Docker, et savoir choisir entre privilégié et non privilégié.

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-pct.html>

---

## 1. VM, LXC, Docker : trois choses différentes 🧠

```
   ┌─────────── VM (KVM) ───────────┐   ┌────────── LXC ──────────┐
   │  Application                   │   │  Application            │
   │  Bibliothèques                 │   │  Bibliothèques          │
   │  ─────── noyau invité ─────────│   │  (userland complet)     │
   │  Matériel virtualisé (QEMU)    │   │                         │
   └────────────────┬───────────────┘   └───────────┬─────────────┘
                    │                               │
   ┌────────────────┴───────────────────────────────┴─────────────┐
   │            NOYAU DE L'HÔTE  (namespaces, cgroups)            │
   └──────────────────────────────────────────────────────────────┘
```

| | VM KVM | LXC | Docker |
|---|---|---|---|
| Noyau | le sien | celui de l'hôte | celui de l'hôte |
| Démarrage | 20-60 s | **< 2 s** | < 1 s |
| Empreinte RAM | ≥ 512 Mo | **~20 Mo** | ~10 Mo |
| OS invité | n'importe lequel | Linux uniquement | image applicative |
| Philosophie | machine | **machine légère** (init, cron, ssh…) | **un processus** |
| Live migration | ✅ | ❌ (offline seulement) | n/a |
| Isolation | forte (hyperviseur) | moyenne (noyau partagé) | moyenne |

👉 **Règle pratique** : LXC pour les services d'infra internes (DNS, proxy, monitoring,
runner CI) où l'on veut de la densité. VM dès qu'on veut de l'isolation forte, un noyau
particulier, du live migration, ou qu'on héberge du code tiers.

🪤 **Docker dans un LXC** : possible (conteneur privilégié + `nesting=1` + `keyctl=1`),
mais fragile et déconseillé en production. Docker dans une **VM**, toujours.

---

## 2. Privilégié ou non privilégié ? 🔐

```
   NON PRIVILÉGIÉ (défaut, recommandé)      PRIVILÉGIÉ
   ────────────────────────────────────     ─────────────────────────
   root du CT (uid 0)                       root du CT (uid 0)
        │  user namespace mapping                │
        ▼                                        ▼
   uid 100000 sur l'hôte                    uid 0 sur l'hôte  ⚠️
   → une évasion ne donne aucun droit       → une évasion = root sur l'hôte
```

Le non privilégié est le défaut depuis longtemps. On n'utilise le privilégié que
lorsqu'on ne peut vraiment pas faire autrement (montage FUSE, certains modules noyau,
NFS monté dans le CT).

---

## 3. Créer le conteneur Alpine 🌐

`pve → Create CT`

### Onglet **General**
| Champ | Valeur |
|---|---|
| CT ID | `111` |
| Hostname | `ct-alpine` |
| Resource Pool | `lab` |
| Unprivileged container | ✅ |
| Nesting | ✅ (utile, sans danger en non privilégié) |
| Password | `Formation2026!` |
| SSH public key | collez `~/.ssh/id_ed25519.pub` |

### Onglet **Template**
`local` → `alpine-3.22-default_...amd64.tar.xz`

### Onglet **Disks**
`local-lvm`, **2** GiB. Oui, deux. Alpine tient dans 150 Mo.

### Onglet **CPU / Memory**
`1` core · `256` MiB RAM · `128` MiB swap

### Onglet **Network**
| Champ | Valeur |
|---|---|
| Name | `eth0` |
| Bridge | `vmbr0` |
| IPv4 | **DHCP** (le LAN de la salle, comme `srv01`) |
| Firewall | ✅ |

### Onglet **DNS**
`1.1.1.1`, domaine `lab.local`.

---

## 4. La même chose en CLI 🖥️

```bash
CTID=111
TPL=$(pveam list local | awk '/alpine/ {print $1}' | head -1)

pct create $CTID $TPL \
  --hostname ct-alpine \
  --pool lab \
  --unprivileged 1 \
  --features nesting=1 \
  --password 'Formation2026!' \
  --ssh-public-keys /root/.ssh/authorized_keys \
  --rootfs local-lvm:2 \
  --cores 1 --memory 256 --swap 128 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,ip=dhcp \
  --nameserver 1.1.1.1 --searchdomain lab.local \
  --onboot 1 \
  --start 1

pct list
pct config $CTID
pct exec $CTID -- ip -4 -br a show eth0      # l'adresse obtenue en DHCP
```

📌 Notez l'IP du conteneur, elle sert depuis le PC. Dans une variable sur le nœud :

```bash
IP=$(pct exec $CTID -- ip -4 -o a show eth0 | awk '{print $4}' | cut -d/ -f1)
echo $IP
```

Le fichier correspondant :

```bash
cat /etc/pve/lxc/$CTID.conf
```

---

## 5. Entrer et jouer dedans

```bash
pct enter $CTID
```

Comparez avec Debian :

```sh
cat /etc/os-release
apk update
apk add --no-cache nginx curl htop
rc-update add nginx default
rc-service nginx start

echo "<h1>Hello depuis ct-alpine 🏔️</h1>" > /var/lib/nginx/html/index.html
curl -s localhost | head
df -h /
free -m
exit
```

Depuis votre PC (avec l'IP relevée au §4) :

```bash
curl http://<IP-de-ct-alpine>/
```

🧠 Alpine utilise **OpenRC** (pas systemd), **apk** (pas apt), **musl libc**
(pas glibc) et **busybox**. Résultat : ~5 Mo d'image de base, un démarrage quasi
instantané, et parfois un binaire compilé pour glibc qui refuse de tourner.

### Exécuter sans entrer

```bash
pct exec $CTID -- apk info -v | head
pct exec $CTID -- rc-status
```

---

## 6. Le second conteneur : Rocky Linux 🪨

Alpine, c'est le minimalisme. Rocky Linux, c'est l'inverse : la famille RHEL, avec
`dnf`, `systemd`, SELinux et `firewalld`.

```bash
CTID2=112
pveam update
pveam available --section system | grep -i rocky
```

```bash
# Prenez le nom exact retourné ci-dessus (ex. rockylinux-10-default_...)
TPL2=$(pveam available --section system | awk '/rockylinux/ {print $2}' | sort | tail -1)
pveam download local $TPL2
TPL2LOCAL=$(pveam list local | awk '/rockylinux/ {print $1}' | head -1)

pct create $CTID2 $TPL2LOCAL \
  --hostname ct-rocky --pool lab \
  --unprivileged 1 \
  --password 'Formation2026!' \
  --ssh-public-keys /root/.ssh/authorized_keys \
  --rootfs local-lvm:6 --cores 1 --memory 512 --swap 256 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,ip=dhcp \
  --nameserver 1.1.1.1 --searchdomain lab.local \
  --onboot 1 --start 1
```

```bash
pct exec $CTID2 -- bash -c '
  cat /etc/os-release | head -2
  dnf -y install nginx procps-ng iproute >/dev/null 2>&1
  echo "<h1>Servi par ct-rocky 🪨</h1>" > /usr/share/nginx/html/index.html
  systemctl enable --now nginx
  ss -tlnp | grep :80
'
IP2=$(pct exec $CTID2 -- ip -4 -o a show eth0 | awk '{print $4}' | cut -d/ -f1)
curl -s http://$IP2/
```

Depuis votre PC :

```bash
curl http://<IP-de-ct-rocky>/
```

🪤 **Trois surprises dans un LXC Rocky :**

| Surprise | Explication | Contournement |
|---|---|---|
| `firewalld` absent ou inopérant | Il a besoin de netfilter côté noyau, refusé aux CT non privilégiés | On filtre au niveau Proxmox — c'est mieux (TP 09) |
| SELinux en mode « disabled » | Le CT hérite du noyau de l'hôte, qui n'a pas de politique SELinux | Normal ; l'isolation vient des namespaces |
| `systemctl` fonctionne quand même | LXC lance un vrai `systemd` comme PID 1 dans le conteneur | ✅ c'est la force de LXC face à Docker |

### La comparaison qui parle 📊

```bash
for c in $CTID $CTID2; do
  echo "═══ CT $c ═══"
  pct exec $c -- sh -c 'grep PRETTY /etc/os-release; df -h / | tail -1; free -m | sed -n 2p'
done
pct list
```

Un ordre de grandeur d'écart :

```
   Alpine  →  ~ 60 Mo de disque,   ~ 10 Mo de RAM,  démarrage < 1 s
   Rocky   →  ~ 900 Mo de disque,  ~ 90 Mo de RAM,  démarrage ~ 4 s
```

🧠 Rocky apporte l'écosystème RHEL : paquets signés, cycle de vie de 10 ans,
compatibilité avec les logiciels d'entreprise. Alpine apporte la densité. Le choix
dépend de ce que vous hébergez.

Côté hôte :

```bash
top -bn1 | head -12
pct list
```

---

## 7. Bind mount : partager un dossier de l'hôte 🔗

Cas d'usage réel : un conteneur nginx qui sert des fichiers stockés sur l'hôte.

```bash
mkdir -p /srv/www
echo "<h1>Servi depuis l'hôte</h1>" > /srv/www/index.html

pct set $CTID -mp0 /srv/www,mp=/var/lib/nginx/html
pct reboot $CTID
sleep 5
curl http://$IP/
```

🪤 **Le piège du non privilégié** : les uid du conteneur sont décalés de 100000 sur
l'hôte. Un fichier appartenant à `root` sur l'hôte apparaît comme `nobody` dans le CT.

```bash
ls -ln /srv/www
pct exec $CTID -- ls -ln /var/lib/nginx/html
```

Solution : donner la propriété à l'uid mappé côté hôte.

```bash
chown -R 100000:100000 /srv/www
pct exec $CTID -- ls -ln /var/lib/nginx/html    # maintenant root:root dans le CT
```

---

## 8. Sauvegarde, restauration, template

```bash
# Sauvegarde
vzdump $CTID --storage local --mode snapshot --compress zstd
ls -lh /var/lib/vz/dump/ | grep lxc

# Restauration sous un nouvel ID
pct restore 113 /var/lib/vz/dump/vzdump-lxc-$CTID-*.tar.zst \
    --storage local-lvm --hostname ct-restore
pct list
pct destroy 113 --purge
```

Transformer un CT en template :

```bash
# On travaille sur une COPIE : ct-rocky nous servira encore aux TP 08 et 09
pct stop $CTID2 && pct clone $CTID2 114 --hostname ct-tpl && pct start $CTID2
pct template 114
pct clone 114 115 --hostname ct-clone
pct list
pct destroy 115 --purge ; pct destroy 114 --purge
```

🪤 **Un template est irréversible.** On ne peut plus démarrer le CT d'origine, seulement
le cloner — d'où la copie intermédiaire ci-dessus.

---

## 9. Limites de ressources en direct 🎛️

```bash
pct set $CTID --memory 512 --cores 2          # à chaud, sans redémarrage
pct exec $CTID -- free -m

# Limitation d'I/O et de réseau
pct set $CTID --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1,rate=10   # 10 Mo/s — ⚠ --net0 REMPLACE toute la carte : on redonne ip= et firewall=
pct exec $CTID -- ip -br a
```

Côté hôte, tout passe par les cgroups v2 :

```bash
cat /sys/fs/cgroup/lxc/$CTID/memory.max
cat /sys/fs/cgroup/lxc/$CTID/cpu.max
```

---

## ✅ Checklist de validation

- [ ] `ct-alpine` tourne et répond en HTTP depuis mon PC, sur l'IP obtenue en DHCP
- [ ] `ct-rocky` tourne et répond en HTTP depuis mon PC (`curl http://<IP-de-ct-rocky>/`)
- [ ] `pct enter` fonctionne, `apk` et `dnf` installent des paquets
- [ ] J'ai comparé les empreintes disque/RAM Alpine vs Rocky
- [ ] Le bind mount fonctionne et je comprends le décalage d'uid (100000)
- [ ] J'ai sauvegardé, restauré et détruit un CT
- [ ] J'ai créé un template LXC et cloné à partir de lui
- [ ] Je sais expliquer en une phrase la différence LXC / VM / Docker

---

## 🎁 Bonus

1. Démarrez 10 conteneurs Alpine d'un coup et mesurez la RAM consommée :
   ```bash
   for i in $(seq 180 189); do
     pct clone 111 $i --hostname alpine-$i && pct start $i
   done
   free -m ; pct list
   for i in $(seq 180 189); do pct stop $i; pct destroy $i --purge; done
   ```
   Comparez avec ce que coûteraient 10 VM.
2. Chronométrez : `time pct start 111` vs `time qm start 101` (après un `pct stop 111` et un `qm stop 101`).
3. Lisez `/proc/$(pct exec 111 -- sh -c 'echo $$')/ns/` sur l'hôte — vous voyez les
   namespaces qui isolent le conteneur.
4. **Docker dans Rocky** : essayez `pct exec 112 -- dnf install -y podman` puis
   `podman run --rm alpine echo ok`. Podman en *rootless* passe souvent là où Docker
   échoue. Comprenez pourquoi (indice : pas de démon, pas de `/var/run/docker.sock`).

➡️ Suite : [TP 06 — Exploration complète de l'interface Proxmox](06-exploration-interface.md)
