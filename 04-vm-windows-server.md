# TP 04 — VM Windows Server 2025 via ISO, console et RDP 🪟

⏱️ **1 h 30** · Jour 1

Objectif : installer un Windows Server 2025 sur Proxmox dans les règles de l'art
(VirtIO, TPM, agent invité), maîtriser la console noVNC/SPICE, puis y accéder en RDP.

📖 Doc : <https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices>

---

## 1. Pourquoi Windows mérite son propre TP 🧠

Une VM Linux se contente des pilotes VirtIO présents dans le noyau. Windows, non :
il ne connaît **ni le contrôleur de disque VirtIO, ni la carte réseau VirtIO**.
Résultat classique :

```
   ┌─────────────────────────────────────────────────┐
   │  Installation de Windows                        │
   │                                                 │
   │   « Nous n'avons trouvé aucun lecteur. »        │
   │                                                 │
   │   [ Charger un pilote ]        [ Suivant ]      │
   └─────────────────────────────────────────────────┘
```

Deux options :
- **Facile** : mettre le disque en `SATA` et la carte en `E1000`. Ça marche… mal.
  Perfs médiocres, pas de TRIM, pas de ballooning.
- **Correcte** : garder VirtIO et **fournir les pilotes** via un second CD-ROM.
  C'est ce qu'on fait ici.

---

## 2. Récupérer les ISO ⬇️

### Windows Server 2025 (évaluation 180 jours)

🔗 <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025>

Inscription rapide, puis choisissez **ISO – 64-bit edition**, langue *English* ou
*French*. Le fichier fait ~5 Go.

Téléversez-le : 🌐 `pve → local → ISO Images → Upload`.
Ou, si le lien direct de votre session le permet :

```bash
cd /var/lib/vz/template/iso
curl -fLO "<url-obtenue-sur-evalcenter>"
ls -lh *.iso
```

### Pilotes VirtIO pour Windows

C'est un ISO libre, maintenu par le projet Fedora/oVirt :

```bash
cd /var/lib/vz/template/iso
curl -fLO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
ls -lh virtio-win.iso
```

🔗 Page du projet : <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/>

---

## 3. Créer la VM 🌐

`pve → Create VM`

### General
| Champ | Valeur |
|---|---|
| Node | `pve` |
| VM ID | `102` |
| Name | `win01` |
| Resource Pool | `lab` |

### OS
| Champ | Valeur |
|---|---|
| ISO image | `<votre ISO Windows Server 2025>` |
| Type | **Microsoft Windows** |
| Version | **11 / 2022 / 2025** |

🧠 Proxmox adapte à ce choix les *hints* passés à QEMU (horloge Hyper-V,
énumérateurs) : les performances de Windows en dépendent.

### System
| Champ | Valeur | Pourquoi |
|---|---|---|
| Graphic card | `Default` | |
| Machine | **`q35`** | requis pour PCIe et TPM |
| BIOS | **`OVMF (UEFI)`** | Windows Server 2025 exige UEFI + Secure Boot |
| Add EFI Disk | ✅ `local-lvm` | |
| Pre-Enroll keys | ✅ | ⚠️ à cocher ici, contrairement à Linux : Secure Boot |
| SCSI Controller | `VirtIO SCSI single` | |
| Qemu Agent | ✅ | |
| **Add TPM** | ✅ `local-lvm`, version **v2.0** | exigence Windows 11/2025 |

### Disks
| Champ | Valeur |
|---|---|
| Bus/Device | `SCSI 0` |
| Storage | `local-lvm` |
| Disk size | `50` GiB |
| Cache | `Write back` |
| Discard | ✅ |
| SSD emulation | ✅ |
| IO thread | ✅ |

🧠 **`Write back` pour Windows** : l'installeur et les mises à jour font énormément de
petites écritures synchrones, le cache en écriture différée fait une grosse différence.
À réserver aux hôtes sur onduleur — sinon `No cache` ou `Direct sync`.

### CPU / Memory
| Champ | Valeur |
|---|---|
| Sockets / Cores | `1` / `4` |
| Type | `host` |
| Memory | `6144` MiB |
| Ballooning | ✅ (min 2048) |

⚠️ Windows Server 2025 avec l'expérience de bureau tient difficilement sous 4 Go.
Prévoyez 6 Go, 8 si votre hôte le permet.

### Network
| Champ | Valeur |
|---|---|
| Bridge | `vmbr0` |
| Model | **`VirtIO (paravirtualized)`** |
| Firewall | ✅ |

**Ne démarrez pas encore.**

---

## 4. Ajouter le CD des pilotes VirtIO 💿

Une VM peut avoir plusieurs lecteurs. On ajoute le second sur `ide0`.

🌐 `win01 → Hardware → Add → CD/DVD Drive` → `IDE 0` → `virtio-win.iso`

Ou en CLI, ce qui permet aussi de relire la configuration complète :

```bash
VMID=102

qm set $VMID --ide0 local:iso/virtio-win.iso,media=cdrom
qm config $VMID
```

Configuration complète en une seule commande (pour référence) :

```bash
qm create $VMID \
  --name win01 --pool lab \
  --ostype win11 \
  --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 local-lvm:1,version=v2.0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:50,cache=writeback,discard=on,ssd=1,iothread=1 \
  --ide2 local:iso/<windows-server-2025>.iso,media=cdrom \
  --ide0 local:iso/virtio-win.iso,media=cdrom \
  --boot order='ide2;scsi0' \
  --cores 4 --sockets 1 --cpu host \
  --memory 6144 --balloon 2048 \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --agent enabled=1 \
  --serial0 socket \
  --vga std
```

Le port série (`COM1` côté Windows) ne sert pas de console ici : il recevra les journaux
de Cloudbase-Init au §10, lisibles avec `qm terminal 102`.

---

## 5. Installer Windows 🪟

```bash
qm start $VMID
```

🌐 `win01 → Console`. **Appuyez sur une touche rapidement** quand s'affiche
*Press any key to boot from CD* — sinon vous atterrissez dans le shell UEFI.

> 🪤 Coincé dans le shell UEFI ? Tapez `exit`, puis `Boot Manager` →
> `UEFI QEMU DVD-ROM`. Ou `qm reset $VMID` et soyez plus rapide.

### Le moment crucial : le disque invisible

Écran *« Où souhaitez-vous installer Windows ? »* → **aucun disque**.

1. Cliquez sur **Charger un pilote** / *Load driver*
2. **Parcourir** → le lecteur `virtio-win`
3. Chemin : `E:\vioscsi\2k25\amd64\`
   (si `2k25` n'existe pas encore dans votre ISO, prenez `2k22`)
4. Sélectionnez **Red Hat VirtIO SCSI pass-through controller** → Suivant

💥 Le disque de 50 Go apparaît.

**Tant qu'on y est, chargez aussi les autres pilotes** (bouton *Charger un pilote* à
nouveau, en décochant « masquer les pilotes incompatibles ») :

| Pilote | Chemin |
|---|---|
| Réseau | `E:\NetKVM\2k25\amd64\` |
| Ballooning | `E:\Balloon\2k25\amd64\` |
| Série (agent) | `E:\vioserial\2k25\amd64\` |

Puis : Suivant → l'installation démarre. ☕ **15 à 25 minutes.**

### Choix pendant l'installation

| Écran | Réponse |
|---|---|
| Édition | **Standard Evaluation (Desktop Experience)** — on veut le bureau graphique |
| Type d'installation | Personnalisée |
| Mot de passe Administrateur | `Formation2026!` |

---

## 6. Post-installation : les 4 gestes indispensables 🔧

Ouvrez la console. Windows démarre, mais **sans carte réseau** (pilote non installé
si vous avez sauté l'étape ci-dessus).

### 6.1 Installer tous les pilotes d'un coup

Explorateur → lecteur `virtio-win` → exécutez **`virtio-win-gt-x64.msi`**
(*guest tools*). Suivant, suivant, terminer.

### 6.2 Installer l'agent invité QEMU

Toujours sur le CD virtio : `guest-agent\qemu-ga-x86_64.msi`.

Vérifiez côté hôte :

```bash
qm agent $VMID ping && echo "✔ agent OK"
qm agent $VMID network-get-interfaces | jq -r '.[]|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")."ip-address"'
qm guest cmd $VMID get-osinfo
```

🧠 Sans l'agent, `qm shutdown` envoie un signal ACPI que Windows peut ignorer
(« une application empêche l'arrêt »). Avec l'agent, c'est un vrai arrêt propre.

### 6.3 Vérifier le réseau

Une fois le pilote `NetKVM` installé, Windows obtient son adresse **en DHCP** sur le
LAN de la salle, comme `srv01`. Rien à saisir : relevez-la.

| Où | Comment |
|---|---|
| Dans Windows | `ipconfig` dans un PowerShell |
| Côté Proxmox | Summary de la VM (grâce à l'agent, §6.2) |

```powershell
ipconfig
Test-NetConnection 1.1.1.1
Rename-Computer -NewName "WIN01" -Restart
```

> Si la salle n'a pas de DHCP, le formateur vous attribue une adresse dans `.200`–`.250` :
> ```powershell
> $if = (Get-NetAdapter | Where-Object Status -eq 'Up').ifIndex
> New-NetIPAddress -InterfaceIndex $if -IPAddress 172.30.30.___ `
>                  -PrefixLength 24 -DefaultGateway 172.30.30.2
> Set-DnsClientServerAddress -InterfaceIndex $if -ServerAddresses 1.1.1.1,8.8.8.8
> ```

📌 **Notez l'IP de `win01`** : le RDP (§8) et les tests de firewall du TP 09 en auront
besoin.

### 6.4 Activer RDP

```powershell
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Bureau à distance"
Get-NetFirewallRule -DisplayGroup "Bureau à distance" | Select DisplayName,Enabled
```

Ou : `Gestionnaire de serveur → Serveur local → Bureau à distance → Activer`.

---

## 7. La console Proxmox : noVNC vs SPICE vs xterm.js 🖥️

```
   ┌──────────────┬────────────────────────────────────────────────┐
   │  noVNC       │ HTML5, aucun client à installer.               │
   │  (défaut)    │ Résolution figée, pas de son, presse-papiers   │
   │              │ limité. Parfait pour dépanner.                 │
   ├──────────────┼────────────────────────────────────────────────┤
   │  SPICE       │ Client externe (virt-viewer). Multi-écran,     │
   │              │ son, USB redirigé, presse-papiers bidirection- │
   │              │ nel, résolution dynamique. ★ pour Windows      │
   ├──────────────┼────────────────────────────────────────────────┤
   │  xterm.js    │ Console SÉRIE, texte pur. Inutile sous Windows,│
   │              │ indispensable pour les cloud-images Linux.     │
   └──────────────┴────────────────────────────────────────────────┘
```

### Utiliser SPICE

Sur le nœud :

```bash
qm set $VMID --vga qxl
qm set $VMID --audio0 device=ich9-intel-hda,driver=spice
qm reboot $VMID
```

Sur votre PC Ubuntu :

```bash
sudo apt install -y virt-viewer
```

🌐 `win01 → Console → dropdown → SPICE` → un fichier `.vv` est téléchargé, votre
navigateur l'ouvre avec `remote-viewer`.

Dans Windows, installez ensuite les **SPICE guest tools** pour la résolution dynamique
et le presse-papiers : 🔗 <https://www.spice-space.org/download.html>

### Les astuces noVNC à connaître

| Besoin | Solution |
|---|---|
| Ctrl+Alt+Suppr | Bouton dans la barre latérale de noVNC |
| Clavier français | Barre latérale → Settings, ou `qm set <vmid> --keyboard fr` |
| Coller du texte | Barre latérale → Clipboard → coller → puis Ctrl+V dans la VM |
| Plein écran | Barre latérale → Fullscreen |

---

## 8. Se connecter en RDP 💻

Depuis votre PC Ubuntu :

```bash
sudo apt install -y freerdp3-x11    # ou remmina, plus graphique

xfreerdp3 /v:<IP-de-win01> /u:Administrateur /p:'Formation2026!' \
          /size:1600x900 /dynamic-resolution /clipboard /cert:ignore
```

> Selon la version d'Ubuntu, le binaire s'appelle `xfreerdp` ou `xfreerdp3`.
> Alternative graphique : `sudo apt install remmina remmina-plugin-rdp`.

✅ Un bureau Windows complet, avec presse-papiers partagé.

### RDP vs console : quand utiliser quoi ?

```
   Console Proxmox (noVNC/SPICE)          RDP
   ─────────────────────────────          ───
   Fonctionne AVANT le réseau             Nécessite le réseau + RDP activé
   Voir le BIOS, le boot, un BSOD         Session utilisateur seulement
   Sauve la mise quand la VM ne           Confort d'utilisation quotidien
   répond plus sur le réseau              Multi-écran, son, redirection
   → dépannage 🔧                          → exploitation 👔
```

🧠 **La console est un accès « hors-bande »** : elle passe par l'hyperviseur, pas par
le réseau de la VM — l'équivalent d'un iDRAC/iLO. Au TP 09, c'est elle qui reste quand
une règle de firewall a coupé le RDP.

---

## 9. Bonnes pratiques Windows sur Proxmox 🎓

| Point | Recommandation |
|---|---|
| Contrôleur disque | `VirtIO SCSI single` + pilote `vioscsi` |
| Carte réseau | `VirtIO` + pilote `NetKVM` |
| Agent | `qemu-ga` **toujours** — arrêt propre + IP visibles |
| Ballooning | Pilote `Balloon` installé, sinon l'option est inopérante |
| TRIM | `discard=on` + `Optimiser les lecteurs` planifié dans Windows |
| Horloge | Windows utilise l'heure **locale** : `qm set <id> --localtime 1` en cas de décalage |
| CPU | `host` pour la perf ; `x86-64-v2-AES` si vous voulez migrer à chaud |
| Sauvegarde | Agent + VSS → snapshots cohérents applicativement |
| Fenêtre de mises à jour | Un Patch Tuesday sur 6 VM Windows = un hôte à genoux. Étalez. |

Test de l'arrêt propre :

```bash
qm shutdown $VMID --timeout 120
qm status $VMID
qm start $VMID
```

---

## 10. Cloudbase-Init : cloud-init pour Windows, et un template ☁️

Au TP 10, les VM Linux naîtront de templates cloud-init : hostname, IP, mot de passe et
clés injectés par Proxmox au premier démarrage. Windows sait faire la même chose avec
**Cloudbase-Init** (<https://cloudbase.it/cloudbase-init/>), qui lit le lecteur cloud-init
que Proxmox attache à la VM. On l'installe dans `win01`, puis on fabrique un template
`tpl-win2025` à partir d'un **clone** : `win01` reste intacte pour les TP 08 et 09.

📖 Doc : <https://cloudbase-init.readthedocs.io/> · Proxmox :
<https://pve.proxmox.com/wiki/Cloud-Init_Support>

### 10.1 Installer Cloudbase-Init dans `win01`

Dans la session RDP ou la console, en PowerShell administrateur :

```powershell
Invoke-WebRequest https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi `
  -OutFile $env:TEMP\CloudbaseInitSetup.msi
Start-Process msiexec.exe -ArgumentList "/i $env:TEMP\CloudbaseInitSetup.msi" -Wait
```

L'assistant graphique s'ouvre. Écran **Configuration options** :

| Option | Valeur | Pourquoi |
|---|---|---|
| Username | `Administrator` | Cloudbase-Init gère le mot de passe de **ce** compte ; pas de second admin |
| Use metadata password | ✅ | le mot de passe vient de `qm set --cipassword`, pas d'un mot de passe aléatoire |
| Run Cloudbase-Init service as LocalSystem | ✅ | le service doit pouvoir renommer la machine et configurer le réseau |
| Serial port for logging | `COM1` | les journaux sortent sur le port série : `qm terminal <vmid>` depuis le nœud |

Dernier écran, **deux cases à laisser décochées** : *Run Sysprep to create a generalized
image* et *Shutdown when Sysprep terminates*. On ne généralise **pas** `win01` : ce
serait la rendre inutilisable pour la suite. Le Sysprep se fera sur le clone (§10.3).

### 10.2 Configurer le service pour Proxmox

Proxmox génère pour un `ostype` Windows un lecteur cloud-init au format **`configdrive2`**
(OpenStack), le format par défaut de Cloudbase-Init. Il reste à lui dire quoi appliquer.
Les deux fichiers sont dans `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\`.

`cloudbase-init.conf` (le premier démarrage d'un clone) :

```ini
[DEFAULT]
username=Administrator
groups=Administrators
inject_user_password=true
first_logon_behaviour=no
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
verbose=true
debug=true
logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
logfile=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
logging_serial_port_settings=COM1,115200,N,8
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
allow_reboot=true
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,
        cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,
        cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,
        cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,
        cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,
        cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,
        cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,
        cloudbaseinit.plugins.common.userdata.UserDataPlugin,
        cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
```

Dans `cloudbase-init-unattend.conf` (exécuté pendant la phase Sysprep du clone), les
mêmes `username`, `inject_user_password`, `first_logon_behaviour` et `metadata_services`.

🪤 Trois réglages qui font la différence, tous les trois documentés dans les fils du forum
Proxmox : `inject_user_password=true` **et** `SetUserPasswordPlugin` dans la liste, sinon le
mot de passe de `--cipassword` n'est jamais appliqué ; `first_logon_behaviour=no`, sinon
Windows exige un changement de mot de passe à la première ouverture de session ;
`username=Administrator`, la valeur qui compte est celle de ce fichier, pas `--ciuser`.

Test à blanc, sans lecteur cloud-init, le service doit démarrer et journaliser :

```powershell
Restart-Service cloudbase-init
Get-Content "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log" -Tail 20
```

`No metadata service found` est la sortie attendue : pas de lecteur cloud-init sur `win01`.

### 10.3 Le template : cloner, généraliser, sceller

Sur le nœud, `win01` arrêtée proprement :

```bash
qm shutdown 102 --timeout 120
qm clone 102 193 --name tpl-win2025 --full 1
qm start 102                      # win01 reprend sa vie, on ne la touche plus
qm start 193
```

Dans le **clone** (`193 → Console`), en PowerShell administrateur, le Sysprep avec le
fichier de réponses fourni par Cloudbase-Init :

```powershell
& "C:\Windows\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown `
  /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
```

La VM se généralise (SID, pilotes, activation) puis s'éteint. Sur le nœud :

```bash
qm set 193 --ide0 none --ide2 local-lvm:cloudinit --citype configdrive2
qm set 193 --boot order=scsi0
qm template 193
```

🧠 Le lecteur cloud-init remplace l'ISO Windows sur `ide2`. `--citype configdrive2` est le
défaut pour un `ostype` Windows, on l'écrit pour que ce soit lisible. 🪤 **L'`ostype` doit
être Windows avant tout `--cipassword`** : sinon Proxmox hache le mot de passe comme pour
Linux, et Cloudbase-Init l'applique tel quel, haché.

### 10.4 Le test : un clone qui se configure seul

```bash
qm clone 193 104 --name wintest --full 1
qm set 104 --ciuser Administrator --cipassword 'Formation2026!' --ipconfig0 ip=dhcp
qm start 104
qm terminal 104                   # les journaux Cloudbase-Init défilent sur COM1 — Ctrl+O
```

Comptez deux à trois minutes et un ou deux redémarrages (passes *specialize* et *oobe*,
puis renommage). Ensuite :

```bash
qm agent 104 get-host-name        # → wintest
qm agent 104 network-get-interfaces | jq -r '.[]|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")|."ip-address"'
```

Depuis le PC, RDP sur cette IP avec `Administrator` / `Formation2026!`, sans demande de
changement de mot de passe. Puis :

```bash
qm stop 104 && qm destroy 104 --purge
```

Ce template servira au TP 21 (`adm-<nœud>`, adressé en statique via `--ipconfig0`).

---

## 11. Rôle Active Directory (optionnel, si le temps le permet) 🏢

Un aperçu de ce que devient cette VM en usage réel :

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName "lab.local" -DomainNetbiosName "LAB" `
                   -InstallDns -Force -SafeModeAdministratorPassword `
                   (ConvertTo-SecureString "Formation2026!" -AsPlainText -Force)
```

La VM redémarre en contrôleur de domaine. On ne va pas plus loin dans cette formation.

---

## ✅ Checklist de validation

- [ ] Windows Server 2025 est installé sur un disque **VirtIO SCSI**
- [ ] La carte réseau est en **VirtIO** et fonctionne
- [ ] `qm agent 102 ping` répond
- [ ] Le Summary de la VM affiche l'IP de Windows, et je l'ai notée
- [ ] La console noVNC fonctionne et j'ai envoyé un Ctrl+Alt+Suppr
- [ ] SPICE fonctionne avec `remote-viewer`
- [ ] `xfreerdp3` ouvre une session RDP depuis mon PC
- [ ] `qm shutdown` arrête proprement la VM (pas de timeout)
- [ ] Cloudbase-Init est installé dans `win01`, `Administrator` + mot de passe metadata + COM1
- [ ] Le template `tpl-win2025` (193) existe, et un clone a pris son hostname et son mot de passe tout seul
- [ ] Je sais expliquer pourquoi Windows a besoin de l'ISO virtio-win

---

## 🎁 Bonus

1. **Mesurez l'écart VirtIO / SATA** : créez un second disque en `SATA`, puis lancez
   CrystalDiskMark ou `winsat disk` sur chacun.
2. **Snapshot avant Windows Update** :
   ```bash
   qm snapshot 102 avant-wu --vmstate 1
   ```
   Lancez les mises à jour, puis `qm rollback 102 avant-wu`.
3. **IP statique par cloud-init** : clonez `193` avec
   `--ipconfig0 ip=172.30.30.240/24,gw=172.30.30.2 --nameserver 1.1.1.1` (adresse du pot
   commun, à demander au formateur) et vérifiez `ipconfig` dans la VM.
4. Comparez la consommation RAM affichée par Proxmox et par le Gestionnaire des tâches
   Windows, ballooning activé puis désactivé.

➡️ Fin du jour 1 🎉 · Suite : [TP 05 — Conteneurs LXC Alpine et Rocky](05-lxc-alpine-rocky.md)
