# TP 03 — Première VM Debian 13 via ISO netinstall 🖥️

⏱️ **1 h 30** · Jour 1

Objectif : créer une VM « à l'ancienne », comprendre chaque paramètre matériel, et
la brancher sur `vmbr0` (le LAN de la salle).

📖 Doc : <https://pve.proxmox.com/pve-docs/chapter-qm.html>

---

## 1. Ce qu'on va construire

```
   ┌──────────── vmbr0 ─────────────┐
   │  hôte $PVE/24                  │
   │                                │
   │   ┌────────────────────────┐   │
   │   │ VM  srv01              │   │
   │   │ VMID  101              │   │
   │   │ Debian 13              │   │
   │   │ 2 vCPU / 2 Go / 20 Go  │   │
   │   │ IP : DHCP de la salle  │   │  ← on la relève après l'install
   │   └────────────────────────┘   │
   └────────────────────────────────┘
                  │
             172.30.30.2 ──→ ☁
```

> La VM est branchée **directement sur le LAN de la salle** et prend son adresse **en
> DHCP**, comme votre PC. On la relèvera dans le Summary de la VM une fois l'agent
> installé (§5). Si la salle n'a pas de DHCP, le formateur vous attribue une adresse
> statique dans la plage `.200`–`.250` — voir [TP 00 §4](00-prerequis-topologie.md).

---

## 2. Création via l'interface web 🌐

`pve → Create VM` (bouton bleu en haut à droite).

### Onglet **General**

| Champ | Valeur |
|---|---|
| Node | `pve` |
| VM ID | `101` |
| Name | `srv01` |
| Resource Pool | `lab` |
| Start at boot | décoché pour l'instant |

### Onglet **OS**

| Champ | Valeur |
|---|---|
| ISO image | `debian-13.x.0-amd64-netinst.iso` |
| Type | `Linux` |
| Version | `6.x - 2.6 Kernel` |

### Onglet **System**

| Champ | Valeur | Pourquoi |
|---|---|---|
| Graphic card | `Default` | |
| Machine | `q35` | Chipset moderne : PCIe natif, requis pour le passthrough |
| BIOS | `OVMF (UEFI)` | UEFI, comme le matériel actuel |
| Add EFI Disk | ✅ sur `local-lvm` | Stocke les variables EFI |
| Pre-Enroll keys | décoché | Évite les soucis de Secure Boot en lab |
| SCSI Controller | `VirtIO SCSI single` | Le plus performant sous Linux |
| Qemu Agent | ✅ | Indispensable (voir §5) |
| Add TPM | non | |

### Onglet **Disks**

| Champ | Valeur |
|---|---|
| Bus/Device | `SCSI 0` |
| Storage | `local-lvm` |
| Disk size | `20` GiB |
| Cache | `Default (No cache)` |
| Discard | ✅ |
| SSD emulation | ✅ |
| IO thread | ✅ |

🧠 **`Discard` + `SSD emulation`** : quand vous supprimez un fichier dans la VM, le
`TRIM` est propagé au stockage. Sans ça, un disque thin ne se dégonfle jamais et
grossit indéfiniment.

### Onglet **CPU**

| Champ | Valeur |
|---|---|
| Sockets | `1` |
| Cores | `2` |
| Type | `host` |

🧠 **`host` vs `x86-64-v2-AES`** : `host` expose toutes les instructions du CPU physique
(AES-NI, AVX…) → meilleures performances. Mais la migration à chaud vers un nœud au CPU
différent devient impossible. Au **jour 4**, en cluster hétérogène, on repassera en
`x86-64-v2-AES`. Retenez ce compromis, c'est une question d'entretien d'embauche.

### Onglet **Memory**

| Champ | Valeur |
|---|---|
| Memory | `2048` MiB |
| Minimum memory | `1024` MiB (active le ballooning) |
| Ballooning Device | ✅ |

🧠 Le **ballooning** permet à l'hôte de reprendre de la RAM non utilisée par la VM
quand il en manque. Utile en lab surchargé, à éviter pour les bases de données.

### Onglet **Network**

| Champ | Valeur |
|---|---|
| Bridge | `vmbr0` |
| Model | `VirtIO (paravirtualized)` |
| VLAN Tag | vide |
| Firewall | ✅ (cochez la case si elle ne l'est pas : on s'en sert au TP 09) |

⚠️ **Ne cochez pas** « Start after created » : on veut d'abord vérifier la config.

---

## 3. La même chose en CLI 🖥️

Parce que c'est ce que vous ferez en vrai, et parce que c'est reproductible.

```bash
VMID=101
ISO=$(ls /var/lib/vz/template/iso/debian-13*-amd64-netinst.iso | head -1 | xargs basename)

qm create $VMID \
  --name srv01 \
  --pool lab \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:20,discard=on,ssd=1,iothread=1 \
  --ide2 local:iso/$ISO,media=cdrom \
  --boot order='scsi0;ide2' \
  --cores 2 --sockets 1 --cpu host \
  --memory 2048 --balloon 1024 \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot 0

qm config $VMID
```

Comparez la sortie de `qm config` avec le fichier réel :

```bash
cat /etc/pve/qemu-server/$VMID.conf
```

🧠 C'est **le même fichier**. Une VM Proxmox, c'est un fichier texte de 20 lignes dans
`/etc/pve`. D'où la facilité de sauvegarde, de versioning… et de casse si on édite
n'importe comment.

---

## 4. Installer Debian

```bash
qm start $VMID
```

Puis 🌐 `VM 101 → Console` (noVNC).

### Réponses de l'installateur

| Écran | Réponse |
|---|---|
| Langue / pays / clavier | Français |
| Hostname | `srv01` |
| Domain | `lab.local` |
| Root password | `Formation2026!` |
| Utilisateur | `eleve` / `Formation2026!` |
| Réseau | **DHCP** (l'installateur le fait tout seul) ⬇ |
| Partitionnement | Assisté – tout dans une seule partition |
| Sélection de logiciels | **décocher** « Environnement de bureau » ; **cocher** « serveur SSH » et « utilitaires usuels du système » |
| GRUB | oui, sur `/dev/sda` |

**Réseau** : l'installateur détecte la carte VirtIO et demande un bail au DHCP de la
salle. Laissez faire. Si la salle n'a pas de DHCP, choisissez « Configurer manuellement »
avec l'adresse fournie par le formateur, la passerelle `172.30.30.2` et les DNS
`1.1.1.1 8.8.8.8`.

☕ L'installation prend 10-15 min. Profitez-en pour lire le §5.

À la fin : retirez l'ISO.

```bash
qm set $VMID --ide2 none,media=cdrom
qm set $VMID --boot order='scsi0'
```

---

## 5. Le QEMU Guest Agent 🤝

Sans agent, Proxmox ne sait **rien** de l'intérieur de la VM. Il peut la démarrer et
lui couper le courant, c'est tout.

```
   Sans agent                        Avec agent
   ──────────                        ──────────
   Shutdown = bouton ACPI            Shutdown = vrai `shutdown -h now`
   IP de la VM : inconnue            IP affichées dans le Summary
   Snapshot : disques « crash        Snapshot : le FS est gelé (fsfreeze)
   consistent »                        → sauvegarde cohérente
   Pas de TRIM après clonage         fstrim automatique
```

Dans la VM (console ou SSH) :

```bash
apt update && apt install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

Sur le nœud :

```bash
qm agent $VMID ping && echo "agent OK"
qm agent $VMID network-get-interfaces | jq -r '.[] | "\(.name) \(."ip-addresses"[]?."ip-address" // "")"'
qm guest cmd $VMID get-osinfo
```

✅ Le Summary de la VM dans l'interface web affiche maintenant son IP. **Notez-la** :
c'est celle que vous utiliserez pour `ssh eleve@<IP-de-srv01>` depuis votre PC.

```bash
# La même chose en une ligne, pour la coller dans une variable
IP=$(qm agent $VMID network-get-interfaces \
     | jq -r '.[]|select(.name!="lo")|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")."ip-address"' | head -1)
echo $IP
```

---

## 6. Manipulations utiles

### Snapshots

```bash
qm snapshot $VMID avant-bidouille --description "Etat propre post-install" --vmstate 0
qm listsnapshot $VMID
```

Cassez volontairement quelque chose dans la VM :

```bash
# DANS la VM
mv /etc/ssh/sshd_config /etc/ssh/sshd_config.hs && systemctl restart ssh
```

Restaurez :

```bash
# Sur le nœud
qm rollback $VMID avant-bidouille
qm start $VMID
```

🪤 `--vmstate 1` inclut la RAM : le rollback restaure la VM **allumée**, exactement dans
l'état où elle était. Beaucoup plus lourd et plus lent. À réserver aux cas où c'est
vraiment utile.

### Redimensionner un disque à chaud

```bash
qm resize $VMID scsi0 +5G
# Dans la VM :
lsblk
growpart /dev/sda 1 ; resize2fs /dev/sda1     # adapter selon le partitionnement
```

### Sauvegarde locale (on prépare le jour 4)

```bash
vzdump $VMID --storage local --mode snapshot --compress zstd --notes-template '{{guestname}}'
ls -lh /var/lib/vz/dump/
```

🧠 Gardez ce réflexe : au **jour 4**, les nœuds sont réinstallés avant la mise en
cluster. Une archive `vzdump` déposée sur un stockage **externe** au nœud (le NFS de
votre poste, TP 14) est ce qui permet de retrouver une VM de l'autre côté.

### Cloner

```bash
qm clone $VMID 103 --name srv02 --full 1
qm destroy 103 --purge        # on nettoie, c'était juste pour voir
```

---

## 7. Comprendre ce qui tourne réellement 🔬

```bash
ps -ef | grep "kvm -id $VMID" | head -1 | tr ' ' '\n' | grep -A1 -E '^-(drive|netdev|device|m|smp)'
```

Vous voyez la ligne de commande QEMU générée par Proxmox. Tous les réglages de
l'interface web finissent ici.

```bash
# Où est le disque ?
lvs | grep $VMID
ls -l /dev/pve/vm-$VMID-disk-0

# Quelle interface tap côté hôte ?
ip -br link | grep "tap$VMID"
bridge link show | grep "tap$VMID"
```

🧠 **`tap101i0`** = interface TAP de la VM `101`, carte `net0`, branchée sur `vmbr0`.
Cette nomenclature vous sauvera au TP 08 quand il faudra tracer un paquet.

```bash
# Capturer le trafic de cette VM en direct
tcpdump -ni tap${VMID}i0 -c 20
```

---

## ✅ Checklist de validation

- [ ] La VM `srv01` démarre et affiche un login
- [ ] Depuis mon PC : `ssh eleve@<IP-de-srv01>` fonctionne
- [ ] Depuis la VM : `ping 1.1.1.1` et `apt update` fonctionnent
- [ ] `qm agent 101 ping` répond
- [ ] Le Summary de la VM affiche son IP, et je l'ai notée
- [ ] Un snapshot existe et le rollback a été testé
- [ ] Une sauvegarde `vzdump` est présente dans `/var/lib/vz/dump/`
- [ ] Je sais retrouver l'interface `tap101i0` et capturer dessus

---

## 🎁 Bonus

1. **Boot UEFI** : `qm set 101 --bios seabios` puis démarrez. Que se passe-t-il ?
   (Indice : le disque EFI ne sert plus, le bootloader n'est pas trouvé.) Remettez `ovmf`.
2. **Hotplug** : `qm set 101 --hotplug disk,network,usb,memory,cpu` puis ajoutez un
   disque à chaud avec `qm set 101 --scsi1 local-lvm:5`. Vérifiez avec `lsblk` dans la VM.
3. **Comparez les modèles de carte réseau** : passez `net0` en `e1000` et refaites un
   `iperf3` contre l'hôte. Mesurez l'écart avec `virtio`. Vous comprendrez pourquoi on ne
   met jamais `e1000` par défaut.

➡️ Suite : [TP 04 — VM Windows Server 2025](04-vm-windows-server.md)
