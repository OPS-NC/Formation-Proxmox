# TP 12 — Terraform : un 3ᵉ LAN et ses règles de firewall 🏗️

⏱️ **1 h 15** · Jour 3

Objectif : ce que vous avez cliqué aux TP 08 et 09, on le décrit en code. Une zone, un
VNet, un subnet, des règles de firewall, deux guests — le tout créé, modifié et détruit
par `terraform apply`.

📖 Provider : <https://registry.terraform.io/providers/bpg/proxmox/latest/docs>

---

## 1. Pourquoi le réseau en IaC ? 🧠

```
   RÉSEAU CLIQUÉ                        RÉSEAU EN CODE
   ─────────────                        ──────────────
   « qui a ajouté ce subnet ? »         git blame
   « c'était quoi avant ? »             git log -p
   recréer en préprod : à la main       terraform apply -var-file=preprod
   revue de sécurité : capture d'écran  revue de la pull request
   un oubli = une faille silencieuse    la CI refuse le merge
```

Un réseau est une **surface d'attaque**. Le décrire en code, c'est le rendre
auditable, reproductible et réversible. C'est le vrai argument, bien avant le gain
de temps.

---

## 2. La cible 🎯

On ajoute une troisième zone : `zsrv`, un réseau de **services d'infrastructure**
(supervision, sauvegarde, dépôts internes).

```
   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐
   │   INTERNAL   │  │     DMZ      │  │  SERVICES  (nouveau) │
   │ 10.N.10.0/24 │  │ 10.N.20.0/24 │  │    10.N.30.0/24      │
   │   TP 08 🖱️   │  │   TP 08 🖱️   │  │   TP 12 🤖 Terraform │
   └──────┬───────┘  └──────┬───────┘  └───────────┬──────────┘
          │                 │                      │
          │  9100 (metrics) │  9100 (metrics)      │
          └────────────────►│◄─────────────────────┘
                            │
              SERVICES peut SCRAPER les deux zones
              mais rien ne peut initier vers SERVICES
                 (sauf SSH depuis INTERNAL)
```

Matrice de flux ciblée :

| De ↓ / Vers → | INTERNAL | DMZ | SERVICES | Internet |
|---|:---:|:---:|:---:|:---:|
| INTERNAL | ✅ | 🟡 22/80/443 | 🟡 22, 3000, 9090 | ✅ |
| DMZ | ❌ | 🟡 80/443 | ❌ | 🟡 80/443/53 |
| **SERVICES** | 🟡 **9100, 22** | 🟡 **9100** | ✅ | 🟡 80/443/53 |

---

## 3. Prendre en main la stack 💻

```bash
cd ~/ProxmoxFormation/lab/terraform/03-sdn-troisieme-lan
cp ../01-premiere-vm/terraform.tfvars .
terraform init
```

Structure :

```
03-sdn-troisieme-lan/
├── versions.tf      provider et versions
├── provider.tf      connexion à l'API
├── variables.tf     eleve, node, endpoint, token, template…
├── sdn.tf           ★ zone + vnet + subnet
├── firewall.tf      ★ règles VNet
├── vms.tf           2 VM dans le nouveau réseau
├── outputs.tf       récapitulatif
└── terraform.tfvars vos valeurs (non versionné)
```

---

## 4. `sdn.tf` — la zone, le VNet, le subnet 🌐

```hcl
locals {
  net_srv  = "10.${var.eleve}.30.0/24"
  gw_srv   = "10.${var.eleve}.30.1"
  net_int  = "10.${var.eleve}.10.0/24"
  net_dmz  = "10.${var.eleve}.20.0/24"
}

resource "proxmox_virtual_environment_sdn_zone_simple" "srv" {
  id     = "zsrv"
  nodes  = [var.pve_node]
  ipam   = "pve"
  dhcp   = "dnsmasq"
  mtu    = 1500
}

resource "proxmox_virtual_environment_sdn_vnet" "srv" {
  id    = "vsrv"
  zone  = proxmox_virtual_environment_sdn_zone_simple.srv.id
  alias = "Services infra e${var.eleve}"
}

resource "proxmox_virtual_environment_sdn_subnet" "srv" {
  subnet  = local.net_srv
  vnet    = proxmox_virtual_environment_sdn_vnet.srv.id
  type    = "subnet"
  gateway = local.gw_srv
  snat    = true

  dhcp_range {
    start_address = "10.${var.eleve}.30.100"
    end_address   = "10.${var.eleve}.30.200"
  }
}
```

🧠 **Les dépendances sont implicites.** Terraform lit
`proxmox_virtual_environment_sdn_zone_simple.srv.id` dans le VNet, en déduit l'ordre
de création, et l'ordre inverse pour la destruction. Vous n'écrivez jamais
« crée la zone d'abord ».

### Le point délicat : l'apply SDN

Le SDN est transactionnel (cf. TP 08 §7). Selon la version du provider, les
ressources SDN déclenchent ou non l'apply automatiquement. Pour être certain,
on l'ajoute explicitement :

```hcl
resource "terraform_data" "sdn_apply" {
  triggers_replace = [
    proxmox_virtual_environment_sdn_zone_simple.srv.id,
    proxmox_virtual_environment_sdn_vnet.srv.id,
    proxmox_virtual_environment_sdn_subnet.srv.id,
    local_file.fw_vsrv.content_md5,
  ]

  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no root@${var.pve_host} 'pvesh set /cluster/sdn'"
  }
}
```

> Si votre version du provider expose un attribut `auto_apply` sur les ressources SDN,
> utilisez-le : c'est plus propre qu'un `local-exec`.
> Vérifiez avec `terraform providers schema -json | jq '.. | .auto_apply? // empty'`.

---

## 5. `firewall.tf` — les règles en code 🛡️

Le fichier `.fw` d'un VNet vit dans `/etc/pve/sdn/firewall/`. On le génère depuis un
template et on le dépose par SSH.

`templates/vsrv.fw.tftpl` :

```
[OPTIONS]
enable: 1
policy_forward: DROP

[RULES]
# Infra : DNS et ICMP vers la gateway
FORWARD ACCEPT -source +sdn/vsrv-all -dest +sdn/vsrv-gateway -p udp -dport 53 -log nolog
FORWARD ACCEPT -source +sdn/vsrv-all -dest +sdn/vsrv-gateway -p icmp -log nolog

# Interne au réseau services
FORWARD ACCEPT -source +sdn/vsrv-all -dest +sdn/vsrv-all -log nolog

# Supervision : SERVICES scrape les autres zones
FORWARD ACCEPT -source +sdn/vsrv-all -dest ${net_int} -p tcp -dport 9100 -log nolog
FORWARD ACCEPT -source +sdn/vsrv-all -dest ${net_dmz} -p tcp -dport 9100 -log nolog
FORWARD ACCEPT -source +sdn/vsrv-all -dest ${net_int} -p tcp -dport 22 -log info

# Accès admin depuis INTERNAL uniquement
FORWARD ACCEPT -source ${net_int} -dest +sdn/vsrv-all -p tcp -dport 22 -log nolog
FORWARD ACCEPT -source ${net_int} -dest +sdn/vsrv-all -p tcp -dport 3000 -log nolog
FORWARD ACCEPT -source ${net_int} -dest +sdn/vsrv-all -p tcp -dport 9090 -log nolog

# La DMZ n'a rien à faire ici
FORWARD DROP   -source ${net_dmz} -dest +sdn/vsrv-all -log warning

# Sortie Internet limitée
FORWARD ACCEPT -source +sdn/vsrv-all -p tcp -dport 80 -log nolog
FORWARD ACCEPT -source +sdn/vsrv-all -p tcp -dport 443 -log nolog
FORWARD ACCEPT -source +sdn/vsrv-all -p udp -dport 53 -log nolog
```

`firewall.tf` :

```hcl
locals {
  fw_vsrv = templatefile("${path.module}/templates/vsrv.fw.tftpl", {
    net_int = local.net_int
    net_dmz = local.net_dmz
  })
}

resource "local_file" "fw_vsrv" {
  content         = local.fw_vsrv
  filename        = "${path.module}/generated/vsrv.fw"
  file_permission = "0640"
}

resource "terraform_data" "push_fw" {
  triggers_replace = [local_file.fw_vsrv.content_md5]

  provisioner "local-exec" {
    command = <<-EOT
      scp -o StrictHostKeyChecking=no ${local_file.fw_vsrv.filename} \
          root@${var.pve_host}:/etc/pve/sdn/firewall/vsrv.fw
      ssh -o StrictHostKeyChecking=no root@${var.pve_host} \
          'pvesh set /cluster/sdn && systemctl reload proxmox-firewall || systemctl restart proxmox-firewall'
    EOT
  }
}
```

🧠 **Ce n'est pas de la triche.** Terraform ne couvre pas encore tous les objets de
l'API Proxmox ; combiner ressources natives et `local-exec` ciblés est une pratique
courante et acceptable — **tant que c'est idempotent et déclenché par un trigger
explicite**, comme ici (`content_md5`).

Alternative plus élégante si vous voulez du 100 % API : le provider
[`Mastercard/restapi`](https://registry.terraform.io/providers/Mastercard/restapi/latest/docs)
permet d'appeler n'importe quel endpoint Proxmox en ressource Terraform.

---

## 6. `vms.tf` — deux VM de supervision 🖥️

```hcl
resource "proxmox_virtual_environment_vm" "mon" {
  name      = "mon01-e${var.eleve}"
  node_name = var.pve_node
  vm_id     = var.eleve * 100 + 50
  pool_id   = "eleve${var.eleve}"
  tags      = ["terraform", "services", "monitoring"]

  clone { vm_id = var.template_debian, full = false }
  agent { enabled = true }

  cpu    { cores = 2, type = "x86-64-v2-AES" }
  memory { dedicated = 2048 }

  network_device {
    bridge   = proxmox_virtual_environment_sdn_vnet.srv.id   # "vsrv"
    model    = "virtio"
    mtu      = 1        # hérite du MTU du VNet — réflexe pour le jour 4
    firewall = true
  }

  initialization {
    ip_config { ipv4 { address = "dhcp" } }
    user_account {
      username = "eleve"
      keys     = [var.ssh_public_key]
    }
  }

  depends_on = [terraform_data.sdn_apply]
}

resource "proxmox_virtual_environment_container" "log" {
  node_name = var.pve_node
  vm_id     = var.eleve * 100 + 51
  pool_id   = "eleve${var.eleve}"
  tags      = ["terraform", "services"]

  initialization {
    hostname = "log01-e${var.eleve}"
    ip_config { ipv4 { address = "dhcp" } }
    user_account { keys = [var.ssh_public_key] }
  }

  operating_system {
    template_file_id = var.lxc_template_alpine
    type             = "alpine"
  }

  network_interface {
    name     = "eth0"
    bridge   = proxmox_virtual_environment_sdn_vnet.srv.id
    firewall = true
  }

  cpu { cores = 1 }
  memory { dedicated = 512, swap = 256 }
  disk { datastore_id = "local-lvm", size = 4 }

  unprivileged = true
  start_on_boot = true
  depends_on   = [terraform_data.sdn_apply]
}
```

🪤 **`depends_on` est ici obligatoire** : sans lui, Terraform peut créer la VM avant que
le bridge `vsrv` n'existe réellement sur le nœud (la ressource SDN est « créée » dès
que le fichier de config est écrit, pas quand l'apply est passé). Erreur typique :
`bridge 'vsrv' does not exist`.

---

## 7. Dérouler 🚀

```bash
terraform fmt
terraform validate
terraform plan -out=tf.plan
```

Lisez le plan : 3 ressources SDN, 1 fichier local, 2 `terraform_data`, 2 guests.

```bash
terraform apply tf.plan
terraform output
```

Vérifications côté nœud :

```bash
ssh root@192.168.50.1N '
  ip -br a | grep vsrv
  cat /etc/pve/sdn/subnets.cfg
  cat /etc/pve/sdn/firewall/vsrv.fw
  systemctl status dnsmasq@zsrv --no-pager | head -3
  qm list | grep mon01
'
```

Tests fonctionnels :

```bash
# depuis mon01 (SERVICES)
ping -c2 10.N.30.1            # ✅ gateway
ping -c2 9.9.9.9              # ❌ ICMP non autorisé vers Internet
curl -sI https://debian.org   # ✅ 443 autorisé
nc -zvw2 10.N.10.<db01> 5432  # ❌ refusé
nc -zvw2 10.N.10.<db01> 9100  # ✅ autorisé (si node_exporter écoute)

# depuis web01 (DMZ)
nc -zvw2 10.N.30.<mon01> 22   # ❌ refusé, et journalisé en warning
```

```bash
ssh root@192.168.50.1N 'tail -20 /var/log/pve-firewall.log'
```

---

## 8. Le vrai test de l'IaC : modifier 🔁

Le développeur demande : « ajoutez le port 9093 (Alertmanager) accessible depuis
INTERNAL ».

1. Ouvrir `templates/vsrv.fw.tftpl`
2. Ajouter une ligne :
   ```
   FORWARD ACCEPT -source ${net_int} -dest +sdn/vsrv-all -p tcp -dport 9093 -log nolog
   ```
3. ```bash
   terraform plan     # → 1 modification : local_file + terraform_data recréés
   terraform apply
   ```
4. `git commit -m "feat(fw): ouvre 9093 Alertmanager depuis INTERNAL — ticket INFRA-512"`

**Trente secondes, tracé dans Git, revu en pull request.** Comparez avec cinq minutes de
clics dans une interface et zéro trace.

### Et le retour arrière ?

```bash
git revert HEAD
terraform apply
```

---

## 9. Détruire proprement 🧹

```bash
terraform plan -destroy
terraform destroy
```

Observez l'ordre : VM → firewall → subnet → VNet → zone. L'inverse exact de la
création. C'est le graphe de dépendances qui travaille.

```bash
ssh root@192.168.50.1N 'ip -br a | grep vsrv; pvesh get /cluster/sdn/zones'
```

🪤 Si la destruction bloque sur « zone in use », c'est qu'un guest est encore branché
sur `vsrv`. Terraform ne connaît que ce qu'il a créé : une VM ajoutée à la main dans
l'UI bloque le `destroy`.

---

## ✅ Checklist de validation

- [ ] `terraform apply` crée la zone, le VNet, le subnet et les règles
- [ ] `ip -br a` montre `vsrv` avec `10.N.30.1/24`
- [ ] Les 2 guests obtiennent une IP par DHCP dans le nouveau réseau
- [ ] SERVICES → INTERNAL:9100 ✅ · SERVICES → INTERNAL:5432 ❌
- [ ] DMZ → SERVICES ❌ et journalisé
- [ ] L'ajout d'une règle se fait en modifiant le template + `apply`
- [ ] `terraform destroy` supprime tout, dans le bon ordre
- [ ] Le dépôt Git ne contient ni `tfstate` ni `tfvars`

---

## 🎁 Bonus

1. **Modulariser** : créez `modules/sdn-zone/` prenant en entrée `nom`, `subnet`,
   `regles` (une liste d'objets), et instanciez-le trois fois pour recréer `zint`,
   `zdmz` et `zsrv` intégralement en code. C'est l'exercice le plus formateur du TP.
2. **Générer la matrice de flux** : un `output` qui produit un tableau markdown à partir
   de la liste de règles. Livrable parfait pour un audit.
3. **CI** : un workflow GitHub Actions qui lance `terraform fmt -check`,
   `terraform validate` et `tflint` sur chaque pull request.
4. **Détecter la dérive** : modifiez `vsrv.fw` à la main sur le nœud, puis
   `terraform plan`. Que détecte-t-il ? Que ne détecte-t-il pas ? (Indice : `local_file`
   ne surveille que le fichier local. Comment feriez-vous mieux ?)

➡️ Suite : [TP 13 — Ansible : inventaire dynamique Proxmox](13-ansible-inventory-proxmox.md)
