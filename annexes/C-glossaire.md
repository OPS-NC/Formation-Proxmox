# Annexe C — Glossaire 📖

Les termes de la formation, en français.

---

## Virtualisation

**KVM** *(Kernel-based Virtual Machine)* — Le module du noyau Linux qui transforme
Linux en hyperviseur. Il utilise les instructions matérielles VT-x/AMD-V. C'est ce qui
fait tourner les VM de Proxmox.

**QEMU** — L'émulateur qui construit la machine virtuelle autour de KVM : le chipset,
les disques, les cartes réseau. QEMU dessine la machine, KVM la fait tourner vite.

**LXC** *(Linux Containers)* — Conteneurs **système** : un userland Linux complet
(init, cron, ssh) partageant le noyau de l'hôte. Entre la VM et Docker.

**Hyperviseur de type 1** — S'exécute directement sur le matériel (Proxmox, ESXi,
Hyper-V). Type 2 = au-dessus d'un OS de bureau (VirtualBox, VMware Workstation).

**Paravirtualisation / VirtIO** — L'invité *sait* qu'il est virtualisé et dialogue
directement avec l'hyperviseur, au lieu de faire semblant de piloter du matériel réel.
Beaucoup plus rapide. Les pilotes s'appellent `virtio-net`, `virtio-scsi`, `virtio-blk`.

**Ballooning** — Un pilote dans l'invité qui « gonfle » pour réserver de la RAM et la
rendre à l'hôte. Permet de surprovisionner la mémoire.

**Passthrough (PCI/USB)** — Attribuer un périphérique physique directement à une VM.
Performances natives, mais la VM devient non migrable.

**OVMF / UEFI** — Le firmware UEFI des VM (par opposition à SeaBIOS, l'ancien BIOS).
Requis par Windows 11/2025 et le Secure Boot.

**TPM** *(Trusted Platform Module)* — Puce (ici virtuelle) qui stocke des clés
cryptographiques. Exigée par Windows 11 et Server 2025.

**Agent invité (QEMU Guest Agent)** — Un démon dans la VM qui dialogue avec
l'hyperviseur : arrêt propre, remontée des IP, gel des systèmes de fichiers pour des
snapshots cohérents. À installer systématiquement.

**fsfreeze** — Le gel temporaire des systèmes de fichiers de l'invité, le temps d'un
snapshot. C'est la différence entre une sauvegarde cohérente et une sauvegarde
« comme si on avait coupé le courant ».

**Linked clone** — Un clone qui partage les blocs du template en copy-on-write.
Instantané et économe, mais il rend le template indestructible.

**Cloud-init** — Le standard de personnalisation au premier démarrage d'une image
cloud : hostname, utilisateurs, clés SSH, réseau, paquets. Ne s'exécute qu'une fois
par *instance-id*.

**Cloud-image** — Une image disque de distribution déjà installée, sans configuration,
conçue pour être personnalisée par cloud-init. À opposer à l'ISO d'installation.

---

## Réseau

**Bridge (`vmbrX`)** — Un switch Ethernet logiciel dans le noyau Linux. Les VM y
branchent leur carte, l'hôte y pose son IP.

**Interface TAP** — L'interface virtuelle côté hôte qui matérialise la carte réseau
d'une VM. Nommée `tap<vmid>i<n>`. C'est là qu'on fait ses captures.

**MTU** *(Maximum Transmission Unit)* — La taille maximale d'un paquet, 1500 octets par
défaut. Toute encapsulation la réduit. Source d'ennuis n°1 en overlay.

**PMTU black hole** — Le paquet est trop gros, il est jeté, et l'ICMP « fragmentation
needed » n'arrive jamais. Symptôme : le ping passe, les gros transferts gèlent.

**SNAT / MASQUERADE** — Réécriture de l'adresse **source** en sortie. Permet à un
réseau privé d'accéder à Internet derrière une IP publique.

**DNAT / port forwarding** — Réécriture de l'adresse **destination** en entrée. Permet
de publier un service interne.

**Conntrack** — Le suivi de connexion du noyau. Il autorise automatiquement les paquets
retour d'une connexion établie. C'est pourquoi **une règle par sens de connexion
suffit**.

**VLAN (802.1Q)** — Un tag de 12 bits dans la trame Ethernet, qui sépare plusieurs
réseaux logiques sur un même câble. 4094 valeurs utilisables.

**QinQ (802.1ad)** — Deux tags VLAN empilés. Un tag « opérateur » + un tag « client ».

**Trunk** — Un port de switch qui transporte plusieurs VLAN tagués. Par opposition à un
port *access*, qui n'en transporte qu'un, sans tag.

---

## SDN et overlay

**SDN** *(Software-Defined Networking)* — Découpler le réseau logique du réseau
physique, et le piloter par configuration centralisée plutôt que port par port.

**Overlay / Underlay** — L'**underlay** est le réseau physique qui transporte. L'**overlay**
est le réseau virtuel construit par-dessus. Ils s'ignorent mutuellement.

**VXLAN** *(Virtual eXtensible LAN)* — Encapsulation d'Ethernet dans de l'UDP
(port 4789). Ajoute **50 octets** d'entête. Permet un L2 étendu sur un réseau IP
quelconque.

**VNI** *(VXLAN Network Identifier)* — L'identifiant de 24 bits d'un réseau VXLAN.
16 millions de valeurs, contre 4094 pour un VLAN.

**VTEP** *(VXLAN Tunnel EndPoint)* — Le point d'entrée/sortie du tunnel. Sur Proxmox,
c'est le nœud lui-même.

**BUM** *(Broadcast, Unknown unicast, Multicast)* — Le trafic qui doit être inondé
partout. Un plan de contrôle comme EVPN en réduit le volume.

**EVPN** *(Ethernet VPN)* — Une extension de BGP qui transporte les informations MAC et
IP. Le « plan de contrôle » de VXLAN : au lieu d'inonder pour apprendre, les nœuds
s'échangent leurs tables par BGP.

**Route type-2 / type-5** — En EVPN, la **type-2** annonce une MAC (et son IP) ; la
**type-5** annonce un préfixe IP entier (un /24). `advertise-subnets` active les type-5.

**VRF** *(Virtual Routing and Forwarding)* — Une table de routage isolée dans le noyau.
Chaque zone EVPN a la sienne : deux VRF peuvent utiliser les mêmes IP sans conflit.

**Anycast gateway** — La même IP **et la même MAC** de passerelle, présentes
simultanément sur tous les nœuds. Une VM parle toujours à sa gateway locale, y compris
après migration. La fonctionnalité clé d'EVPN.

**Exit node** — Un nœud désigné comme porte de sortie du fabric EVPN vers le monde réel.
Il annonce une route par défaut et réalise le SNAT.

**Exit node primaire** — Quand il y a plusieurs exit nodes, celui par lequel tout passe.
**Obligatoire avec SNAT**, car le suivi de connexion est local à chaque nœud.

**IPAM** *(IP Address Management)* — La base qui attribue et mémorise les adresses.
Proxmox en a une intégrée ; on peut brancher NetBox ou phpIPAM.

**Fabric (PVE 9)** — La construction automatique de l'underlay routé entre nœuds :
OpenFabric, OSPF, BGP ou WireGuard. Utile en multi-segment.

**ECMP** *(Equal-Cost Multi-Path)* — Répartir le trafic sur plusieurs chemins de coût
identique. **Incompatible avec le SNAT stateful.**

**Route reflector** — En iBGP, un nœud qui répète les annonces aux autres, pour éviter
le full-mesh en O(n²).

---

## Cluster

**Corosync** — Le bus de messages temps réel entre les nœuds. Détecte les pannes et
calcule le quorum. Très sensible à la latence.

**pmxcfs** — Le système de fichiers distribué de Proxmox, monté sur `/etc/pve`. Une
base SQLite répliquée par Corosync. Tout ce qu'on y écrit apparaît sur tous les nœuds.

**Quorum** — La majorité nécessaire pour prendre une décision : ⌊N/2⌋+1. Sans quorum,
`/etc/pve` passe en lecture seule.

**Split-brain** — Deux moitiés d'un cluster qui se croient toutes deux légitimes. Le
pire scénario : la même VM démarrée deux fois, sur le même disque. Le quorum existe
pour l'empêcher.

**QDevice** — Un votant externe, hors cluster, qui départage. Indispensable sur les
clusters à 2 ou 4 nœuds.

**Fencing** — S'assurer qu'un nœud disparu ne tourne vraiment plus, avant de redémarrer
ses VM ailleurs. Proxmox utilise un **watchdog** : un nœud qui perd le quorum ne peut
plus le caresser, et se fait redémarrer de force.

**Watchdog** — Un compteur (matériel ou `softdog`) qui redémarre la machine s'il n'est
pas réarmé régulièrement.

**CRM / LRM** — *Cluster Resource Manager* : un seul actif, il décide. *Local Resource
Manager* : un par nœud, il exécute.

**Live migration** — Déplacer une VM allumée d'un nœud à l'autre. La RAM est copiée par
itérations successives, puis la VM est figée ~50 ms le temps de la bascule.

---

## Stockage

**Thin provisioning** — Allouer à la demande : un disque de 100 Go n'occupe que ce qui
est réellement écrit.

**Copy-on-Write (COW)** — Ne dupliquer un bloc qu'au moment de sa modification. La base
des snapshots instantanés et des linked clones.

**LVM-Thin** — Le pool logique de Linux avec thin provisioning et snapshots. **Le
stockage par défaut de cette formation** (`local-lvm`), créé par l'installateur sur
ext4. Un thin pool s'agrandit (`lvextend`) mais **ne se réduit jamais** : c'est la
contrainte qui structure le TP 18.

**VG / LV / PV** — *Volume Group* (le réservoir, ici `pve`), *Logical Volume* (une
tranche : `root`, `swap`, `data`, `ceph-osd`), *Physical Volume* (le disque sous-jacent).

**`vg_free`** — L'espace du groupe de volumes **non encore alloué** à un LV. C'est là
qu'on taille le volume destiné à Ceph. Le réglage `maxvz` de l'installateur détermine
combien il en restera.

**ZFS** — Système de fichiers et gestionnaire de volumes : checksums de bout en bout,
snapshots, compression, réplication `zfs send`. Gourmand en RAM et plus rigide à
repartitionner. Non utilisé dans cette formation : ext4 + LVM-thin, et Ceph pour le
partagé.

---

## Ceph

**Ceph** — Stockage distribué : chaque bloc est répliqué sur plusieurs nœuds, sans point
de défaillance unique. La solution de référence pour un cluster Proxmox de 3 nœuds ou
plus.

**MON** *(monitor)* — Détient la carte du cluster : qui existe, où, dans quel état.
Il en faut un nombre **impair** (3 ou 5) pour le quorum. C'est le « corosync » de Ceph.

**MGR** *(manager)* — Métriques, tableau de bord, autoscaler de PG. Un actif, un ou
plusieurs en veille.

**OSD** *(Object Storage Daemon)* — Un démon **par disque ou par volume**. C'est lui qui
stocke réellement les octets et qui réplique vers ses pairs.

**BlueStore** — Le moteur de stockage des OSD : écrit directement sur le périphérique
bloc, sans système de fichiers intermédiaire.

**Pool** — Un espace logique, avec sa règle de réplication. `size 3 / min_size 2` = trois
copies, écriture acceptée dès que deux sont confirmées.

**PG** *(placement group)* — Les « tiroirs » qui répartissent les objets sur les OSD.
L'*autoscaler* en ajuste le nombre automatiquement — historiquement, le calcul manuel de
`pg_num` était la principale source d'erreurs de dimensionnement.

**CRUSH** — L'algorithme qui décide, sans annuaire central, sur quels OSD va chaque
objet. La **CRUSH map** décrit la hiérarchie physique (hosts, racks, salles) et permet
de garantir que les copies ne se retrouvent jamais dans le même domaine de panne.

**RBD** *(RADOS Block Device)* — Le mode bloc de Ceph : c'est ce qui porte les disques
de VM (`vm-store`).

**CephFS** — Le mode système de fichiers POSIX de Ceph, servi par des **MDS** (*metadata
servers*). Pour les ISO, templates et snippets partagés.

**Backfill / Recovery** — La reconstruction des copies manquantes après une panne.
⚠️ À **brider** sur un réseau partagé, sinon elle sature le lien et déstabilise Corosync.

**`nearfull` / `full`** — Seuils d'alerte d'un OSD : 85 % (avertissement) et **95 %
(toutes les écritures du cluster s'arrêtent)**.

**Erasure coding** — Alternative à la réplication : `k` fragments de données + `m` de
parité. Plus économe en espace, mais pénalisant en écriture aléatoire — donc à éviter
pour des disques de VM.

---

## Stockage réseau

**NFS / CIFS** — Partage de fichiers en réseau. Simple, universel, mais dépendant d'un
serveur — donc **un point de défaillance unique**.

**`no_root_squash`** — Option d'export NFS qui laisse le `root` du client rester root
côté serveur. Proxmox en a besoin pour créer les disques de VM. À compenser
systématiquement en restreignant l'export à des adresses IP précises.

**Montage `hard` vs `soft`** — En `hard` (le défaut), une I/O attend indéfiniment que le
serveur revienne. En `soft`, elle échoue après un délai. **Jamais `soft` pour des disques
de VM** : l'invité reçoit des erreurs d'écriture et corrompt son système de fichiers.

**TRIM / discard** — Signaler au stockage que des blocs sont libérés, pour qu'un volume
thin puisse rétrécir.

**RPO / RTO** — *Recovery Point Objective* : combien de données on accepte de perdre.
*Recovery Time Objective* : en combien de temps on doit être de retour. Les deux
chiffres qui pilotent toute stratégie de sauvegarde. Avec Ceph, le RPO est **nul** : les
copies sont synchrones.

---

## Sauvegarde

**Chunk** — Un bloc de ~4 Mo, identifié par son empreinte SHA-256. L'unité de stockage
de PBS.

**Déduplication** — Ne stocker qu'une seule fois un chunk identique, même s'il est
référencé par cent sauvegardes.

**Prune** — Supprimer les **index** de sauvegardes selon une politique de rétention.
Ne libère aucun espace disque.

**Garbage collection** — Supprimer les **chunks** qui ne sont plus référencés par aucun
index. C'est ce qui libère l'espace.

**Verify** — Recalculer l'empreinte de chaque chunk pour détecter la corruption
silencieuse.

**Namespace** — Un cloisonnement logique à l'intérieur d'un datastore PBS. La
déduplication reste globale, mais les droits sont séparés.

**Live restore** — Démarrer la VM immédiatement pendant que ses blocs sont récupérés à
la demande depuis la sauvegarde.

**Règle 3-2-1** — 3 copies, sur 2 supports différents, dont 1 hors site.

---

## Sécurité

**Default deny** — Tout est interdit, sauf ce qui est explicitement autorisé. Le
contraire de *default allow*, où l'on court après les trous.

**DMZ** *(DeMilitarized Zone)* — Un réseau pour les machines exposées, présumées
compromises, et donc coupées du réseau interne.

**Micro-segmentation** — Filtrer jusqu'au niveau de la machine individuelle, pas
seulement entre grands réseaux.

**IPSet** — Un ensemble d'adresses nommé, réutilisable dans les règles. Proxmox en
génère automatiquement pour le SDN (`+sdn/<vnet>-all`).

**nftables** — Le successeur d'iptables dans le noyau Linux. Requis pour les règles de
firewall au niveau VNet.

**Security group** — Un jeu de règles nommé et réutilisable, applicable à plusieurs VM.

**Token API** — Un secret rattaché à un utilisateur, révocable indépendamment. À donner
aux scripts, jamais un mot de passe.

**Privilege separation (`privsep`)** — Un token avec `privsep=1` a ses propres ACL, plus
restreintes que celles de son utilisateur.

---

## Infrastructure as Code

**Déclaratif vs impératif** — « Voici l'état que je veux » (Terraform, Ansible) contre
« fais ceci puis cela » (un script bash).

**Idempotence** — Exécuter deux fois produit le même résultat qu'une fois. Le critère
de qualité d'un playbook Ansible : `changed=0` au second passage.

**State (Terraform)** — Le fichier qui mémorise ce que Terraform a créé. Contient des
secrets : **jamais dans Git**.

**Drift / dérive** — L'écart entre ce que décrit le code et la réalité. Généralement
causé par une modification manuelle.

**Inventaire dynamique** — Un inventaire Ansible généré à la volée depuis une source
externe (ici, l'API Proxmox et ses tags).

**Plan / Apply** — `terraform plan` calcule et affiche la différence ; `apply`
l'exécute. **Toujours lire le plan**, en particulier les `-/+` (recréation).
