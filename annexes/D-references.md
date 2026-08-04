# Annexe D — Références 📚

La documentation officielle est excellente. Prenez le réflexe d'y aller **en premier**.

> 💡 Elle est aussi **embarquée hors ligne** dans votre interface : bouton
> *Documentation* en haut à droite. Il ouvre directement le chapitre correspondant à
> l'écran affiché.

---

## 📖 Documentation Proxmox VE

| Chapitre | Lien | TP concernés |
|---|---|---|
| Sommaire complet | <https://pve.proxmox.com/pve-docs/> | tous |
| Installation | <https://pve.proxmox.com/pve-docs/chapter-pve-installation.html> | 01 |
| Administration système & **réseau** | <https://pve.proxmox.com/pve-docs/chapter-sysadmin.html> | 01, 07 |
| **Stockage** (`pvesm`) | <https://pve.proxmox.com/pve-docs/chapter-pvesm.html> | 02, 14 |
| **Machines virtuelles** (`qm`) | <https://pve.proxmox.com/pve-docs/chapter-qm.html> | 03, 04, 10 |
| **Stockage** — NFS | <https://pve.proxmox.com/pve-docs/chapter-pvesm.html#storage_nfs> | 14 |
| **Conteneurs** (`pct`) | <https://pve.proxmox.com/pve-docs/chapter-pct.html> | 05 |
| **Cloud-init** | <https://pve.proxmox.com/pve-docs/qm.html#qm_cloud_init> | 10 |
| **SDN** ⭐ | <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html> | 08, 12, 17 |
| **Firewall** ⭐ | <https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html> | 09, 12, 17 |
| **Cluster** (`pvecm`) | <https://pve.proxmox.com/pve-docs/chapter-pvecm.html> | 16 |
| **Haute disponibilité** | <https://pve.proxmox.com/pve-docs/chapter-ha-manager.html> | 19 |
| **Sauvegarde / restauration** | <https://pve.proxmox.com/pve-docs/chapter-vzdump.html> | 15 |
| `pveceph` — page de manuel | <https://pve.proxmox.com/pve-docs/pveceph.1.html> | 18 |
| Gestion des utilisateurs | <https://pve.proxmox.com/pve-docs/chapter-pveum.html> | 06 |
| **Ceph** ⭐ | <https://pve.proxmox.com/pve-docs/chapter-pveceph.html> | 18 |
| Notifications | <https://pve.proxmox.com/pve-docs/chapter-notifications.html> | 06 |
| **Viewer d'API** | <https://pve.proxmox.com/pve-docs/api-viewer/> | tous ⭐ |

---

## 📖 Proxmox Backup Server

| Sujet | Lien |
|---|---|
| Documentation | <https://pbs.proxmox.com/docs/> |
| Installation | <https://pbs.proxmox.com/docs/installation.html> |
| Datastores et chunks | <https://pbs.proxmox.com/docs/storage.html> |
| Client en ligne de commande | <https://pbs.proxmox.com/docs/backup-client.html> |
| Maintenance (prune, GC, verify) | <https://pbs.proxmox.com/docs/maintenance.html> |
| Sync et remotes | <https://pbs.proxmox.com/docs/managing-remotes.html> |
| Sauvegarde sur bande | <https://pbs.proxmox.com/docs/tape-backup.html> |

---

## 🌐 Wiki Proxmox

| Page | Lien |
|---|---|
| Accueil du wiki | <https://pve.proxmox.com/wiki/Main_Page> |
| **Software-Defined Network** | <https://pve.proxmox.com/wiki/Software-Defined_Network> |
| **Roadmap et nouveautés** | <https://pve.proxmox.com/wiki/Roadmap> |
| Bonnes pratiques Windows 2025 | <https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices> |
| Cloud-Init Support | <https://pve.proxmox.com/wiki/Cloud-Init_Support> |
| Cluster Manager | <https://pve.proxmox.com/wiki/Cluster_Manager> |
| Network Configuration | <https://pve.proxmox.com/wiki/Network_Configuration> |
| Upgrade 8 → 9 | <https://pve.proxmox.com/wiki/Upgrade_from_8_to_9> |

---

## 🐙 Ceph et LVM

| Sujet | Lien |
|---|---|
| **Deploy Hyper-Converged Ceph Cluster** (wiki) ⭐ | <https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster> |
| Documentation Ceph amont | <https://docs.ceph.com/en/latest/> |
| `ceph-volume` (création d'OSD) | <https://docs.ceph.com/en/latest/ceph-volume/lvm/> |
| BlueStore | <https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/> |
| CRUSH map | <https://docs.ceph.com/en/latest/rados/operations/crush-map/> |
| Placement groups et autoscaler | <https://docs.ceph.com/en/latest/rados/operations/placement-groups/> |
| Ceph Squid → Tentacle (Proxmox) | <https://pve.proxmox.com/wiki/Ceph_Squid_to_Tentacle> |
| LVM — page de manuel `lvmthin` | <https://man7.org/linux/man-pages/man7/lvmthin.7.html> |
| 🪤 « Thin pool cannot be reduced » | <https://bugzilla.redhat.com/show_bug.cgi?id=812731> |
| NFS — `exports(5)` | <https://man7.org/linux/man-pages/man5/exports.5.html> |
| NFS — `nfs(5)` (options de montage) | <https://man7.org/linux/man-pages/man5/nfs.5.html> |

---

## 🔀 Réseau et EVPN

| Sujet | Lien |
|---|---|
| **FRRouting — documentation** | <https://docs.frrouting.org/> |
| FRR — EVPN / VXLAN | <https://docs.frrouting.org/en/latest/evpn.html> |
| FRR — BGP | <https://docs.frrouting.org/en/latest/bgp.html> |
| RFC 7348 — VXLAN | <https://datatracker.ietf.org/doc/html/rfc7348> |
| RFC 7432 — BGP MPLS EVPN | <https://datatracker.ietf.org/doc/html/rfc7432> |
| RFC 9135 — Integrated Routing and Bridging | <https://datatracker.ietf.org/doc/html/rfc9135> |
| Cumulus Linux — EVPN (excellente pédagogie) | <https://docs.nvidia.com/networking-ethernet-software/cumulus-linux/> |
| nftables wiki | <https://wiki.nftables.org/> |

---

## 🤖 Infrastructure as Code

| Outil | Lien |
|---|---|
| **Provider Terraform `bpg/proxmox`** | <https://registry.terraform.io/providers/bpg/proxmox/latest/docs> |
| Dépôt du provider | <https://github.com/bpg/terraform-provider-proxmox> |
| OpenTofu | <https://opentofu.org/docs/> |
| Terraform — bonnes pratiques | <https://developer.hashicorp.com/terraform/language/style> |
| **Ansible — inventaire Proxmox** | <https://docs.ansible.com/ansible/latest/collections/community/general/proxmox_inventory.html> |
| Ansible — collection `community.general` | <https://docs.ansible.com/ansible/latest/collections/community/general/> |
| Ansible — bonnes pratiques | <https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html> |
| ansible-lint | <https://ansible.readthedocs.io/projects/lint/> |
| **cloud-init** | <https://cloudinit.readthedocs.io/> |
| cloud-init — exemples | <https://cloudinit.readthedocs.io/en/latest/reference/examples.html> |

---

## 💿 Images et ISO

| Image | Lien |
|---|---|
| Proxmox VE / PBS / PMG | <https://www.proxmox.com/en/downloads> |
| **Debian 13 netinstall** | <https://www.debian.org/CD/netinst/> |
| Debian — cloud images | <https://cloud.debian.org/images/cloud/> |
| Ubuntu — cloud images | <https://cloud-images.ubuntu.com/> |
| Rocky Linux — cloud images | <https://dl.rockylinux.org/pub/rocky/> |
| Alpine Linux | <https://alpinelinux.org/downloads/> |
| **Windows Server 2025 (évaluation)** | <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025> |
| **Pilotes VirtIO pour Windows** | <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/> |
| Templates LXC officiels | `pveam available --section system` |

---

## 📊 Supervision

| Outil | Lien |
|---|---|
| **Pulse** | <https://github.com/rcourtman/Pulse> |
| Prometheus | <https://prometheus.io/docs/> |
| Grafana — dashboards Proxmox | <https://grafana.com/grafana/dashboards/?search=proxmox> |
| InfluxDB | <https://docs.influxdata.com/> |
| Zabbix — template Proxmox | <https://www.zabbix.com/integrations/proxmox> |
| Checkmk | <https://checkmk.com/integrations/proxmox_ve> |
| Netdata | <https://learn.netdata.cloud/> |

---

## 💬 Communauté

| Ressource | Lien |
|---|---|
| **Forum officiel** ⭐ | <https://forum.proxmox.com/> |
| Bug tracker | <https://bugzilla.proxmox.com/> |
| Liste de développement `pve-devel` | <https://lore.proxmox.com/pve-devel/> |
| Code source | <https://git.proxmox.com/> |
| r/Proxmox | <https://www.reddit.com/r/Proxmox/> |
| **Community scripts** (LXC prêts à l'emploi) | <https://community-scripts.github.io/ProxmoxVE/> |

🪤 Les *community scripts* sont pratiques, mais **lisez toujours le script avant de le
passer à `bash` en root**. `curl -fsSL <url> | less` d'abord.

---

## 🎓 Formation et certification

| Ressource | Lien |
|---|---|
| Formations officielles Proxmox | <https://www.proxmox.com/en/training> |
| Support commercial et abonnements | <https://www.proxmox.com/en/proxmox-virtual-environment/pricing> |

---

## 📌 Les 6 liens à mettre en favori

1. <https://pve.proxmox.com/pve-docs/> — la documentation
2. <https://pve.proxmox.com/pve-docs/api-viewer/> — **l'explorateur d'API**, sous-estimé
3. <https://pve.proxmox.com/pve-docs/chapter-pvesdn.html> — le SDN
4. <https://forum.proxmox.com/> — la communauté
5. <https://registry.terraform.io/providers/bpg/proxmox/latest/docs> — le provider
6. <https://pve.proxmox.com/wiki/Roadmap> — pour suivre les nouveautés
