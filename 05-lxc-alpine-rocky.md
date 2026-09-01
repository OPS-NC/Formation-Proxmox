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

`pveN → Create CT`

### Onglet **General**
| Champ | Valeur |
|---|---|
| CT ID | `N11` (ex. `311`) |
| Hostname | `ct-alpine-eN` |
| Resource Pool | `eleveN` |
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
| IPv4 | **Static** · `172.30.30.<B+2>/24` (élève 3 → `172.30.30.212/24`) |
| Gateway | `172.30.30.2` |
| Firewall | ✅ |

### Onglet **DNS**
`172.30.30.2`, domaine `lab.local`.

---

## 4. La même chose en CLI 🖥️

```bash
CTID=${N}11
N=N
TPL=$(pveam list local | awk '/alpine/ {print $1}' | head -1)

pct create $CTID $TPL \
  --hostname ct-alpine-e$N \
  --pool eleve$N \
  --unprivileged 1 \
  --features nesting=1 \
  --password 'Formation2026!' \
  --ssh-public-keys /root/.ssh/authorized_keys \
  --rootfs local-lvm:2 \
  --cores 1 --memory 256 --swap 128 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,ip=172.30.30.$((195 + N*5 + 2))/24,gw=172.30.30.2 \
  --nameserver 1.1.1.1 --searchdomain lab.local \
  --onboot 1 \
  --start 1

pct list
pct config $CTID
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

Vous voilà dans Alpine. Comparez avec Debian :

```sh
cat /etc/os-release
apk update
apk add --no-cache nginx curl htop
rc-update add nginx default
rc-service nginx start

echo "<h1>Hello depuis ct-alpine-eN 🏔️</h1>" > /var/lib/nginx/html/index.html
curl -s localhost | head
df -h /
free -m
exit
```

Depuis votre PC :

```bash
curl http://172.30.30.$((195 + N*5 + 2))/
```

🧠 Alpine utilise **OpenRC** (pas systemd), **apk** (pas apt), **musl libc**
(pas glibc) et **busybox**. Résultat : ~5 Mo d'image de base, un démarrage
quasi instantané, et parfois des surprises quand un binaire compilé pour glibc
refuse de tourner. Un excellent choix pour des services d'infra simples.

### Exécuter sans entrer

```bash
pct exec $CTID -- apk info -v | head
pct exec $CTID -- rc-status
```

---

## 6. Le second conteneur : Rocky Linux 🪨

Alpine, c'est le minimalisme. Rocky Linux, c'est l'inverse : la famille RHEL, avec
`dnf`, `systemd`, SELinux et `firewalld`. Deux philosophies dans le même hyperviseur.

```bash
N=3     # ⚠ VOTRE numéro d'élève
CTID2=${N}12
pveam update
pveam available --section system | grep -i rocky
```

```bash
# Prenez le nom exact retourné ci-dessus (ex. rockylinux-10-default_...)
TPL2=$(pveam available --section system | awk '/rockylinux/ {print $2}' | sort | tail -1)
pveam download local $TPL2
TPL2LOCAL=$(pveam list local | awk '/rockylinux/ {print $1}' | head -1)

pct create $CTID2 $TPL2LOCAL \
  --hostname ct-rocky-e$N --pool eleve$N \
  --unprivileged 1 \
  --password 'Formation2026!' \
  --ssh-public-keys /root/.ssh/authorized_keys \
  --rootfs local-lvm:6 --cores 1 --memory 512 --swap 256 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,ip=172.30.30.$((195 + N*5 + 4))/24,gw=172.30.30.2 \
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
curl -s http://172.30.30.$((195 + N*5 + 4))/
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

Vous devriez constater un ordre de grandeur d'écart :

```
   Alpine  →  ~ 60 Mo de disque,   ~ 10 Mo de RAM,  démarrage < 1 s
   Rocky   →  ~ 900 Mo de disque,  ~ 90 Mo de RAM,  démarrage ~ 4 s
```

🧠 **Ce n'est pas « Alpine est mieux ».** Rocky vous apporte un écosystème RHEL complet,
des paquets signés, un cycle de vie de 10 ans, et la compatibilité avec les logiciels
d'entreprise. Alpine vous apporte de la densité. Le bon choix dépend de ce que vous
hébergez, pas d'un classement.

Côté hôte, observez la densité globale :

```bash
top -bn1 | head -12
pct list
```

---

## 7. Bind mount : partager un dossier de l'hôte 🔗

Cas d'usage réel : un conteneur nginx qui sert des fichiers stockés sur l'hôte.

```bash
mkdir -p /srv/www-e$N
echo "<h1>Servi depuis l'hôte</h1>" > /srv/www-e$N/index.html

pct set $CTID -mp0 /srv/www-e$N,mp=/var/lib/nginx/html
pct reboot $CTID
sleep 5
curl http://172.30.30.$((195 + N*5 + 2))/
```

🪤 **Le piège du non privilégié** : les uid du conteneur sont décalés de 100000 sur
l'hôte. Un fichier appartenant à `root` sur l'hôte apparaît comme `nobody` dans le CT.

```bash
ls -ln /srv/www-e$N
pct exec $CTID -- ls -ln /var/lib/nginx/html
```

Solution : donner la propriété à l'uid mappé côté hôte.

```bash
chown -R 100000:100000 /srv/www-e$N
pct exec $CTID -- ls -ln /var/lib/nginx/html    # maintenant root:root dans le CT
```

---

## 8. Sauvegarde, restauration, template

```bash
N=3     # ⚠ VOTRE numéro d'élève
# Sauvegarde
vzdump $CTID --storage local --mode snapshot --compress zstd
ls -lh /var/lib/vz/dump/ | grep lxc

# Restauration sous un nouvel ID
pct restore ${N}13 /var/lib/vz/dump/vzdump-lxc-$CTID-*.tar.zst \
    --storage local-lvm --hostname ct-restore-e$N
pct list
pct destroy ${N}13 --purge
```

Transformer un CT en template :

```bash
N=3     # ⚠ VOTRE numéro d'élève
# On travaille sur une COPIE : ct-rocky nous servira encore aux TP 08 et 09
pct stop $CTID2 && pct clone $CTID2 ${N}14 --hostname ct-tpl-e$N && pct start $CTID2
pct template ${N}14
pct clone ${N}14 ${N}15 --hostname ct-clone-e$N
pct list
pct destroy ${N}15 --purge ; pct destroy ${N}14 --purge
```

🪤 **Un template est irréversible.** On ne peut plus démarrer le CT d'origine, seulement
le cloner — d'où la copie intermédiaire ci-dessus.

---

## 9. Limites de ressources en direct 🎛️

```bash
pct set $CTID --memory 512 --cores 2          # à chaud, sans redémarrage
pct exec $CTID -- free -m

# Limitation d'I/O et de réseau
pct set $CTID --net0 name=eth0,bridge=vmbr0,rate=10   # 10 Mo/s
pct exec $CTID -- ip -br a
```

Côté hôte, tout passe par les cgroups v2 :

```bash
cat /sys/fs/cgroup/lxc/$CTID/memory.max
cat /sys/fs/cgroup/lxc/$CTID/cpu.max
```

---

## ✅ Checklist de validation

- [ ] `ct-alpine-eN` tourne et répond en HTTP sur `172.30.30.<B+2>` (élève 3 : `.212`)
- [ ] `ct-rocky-eN` tourne et répond en HTTP sur `172.30.30.<B+4>` (élève 3 : `.214`)
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
   for i in $(seq 80 89); do
     pct clone N11 N$i --hostname alpine-$i && pct start N$i
   done
   free -m ; pct list
   for i in $(seq 80 89); do pct stop N$i; pct destroy N$i --purge; done
   ```
   Comparez avec ce que coûteraient 10 VM.
2. Chronométrez : `time pct start N11` vs `time qm start N01`.
3. Lisez `/proc/$(pct exec N11 -- sh -c 'echo $$')/ns/` sur l'hôte — vous voyez les
   namespaces qui isolent le conteneur.
4. **Docker dans Rocky** : essayez `pct exec N12 -- dnf install -y podman` puis
   `podman run --rm alpine echo ok`. Podman en *rootless* passe souvent là où Docker
   échoue. Comprenez pourquoi (indice : pas de démon, pas de `/var/run/docker.sock`).

➡️ Suite : [TP 06 — Exploration complète de l'interface Proxmox](06-exploration-interface.md)
