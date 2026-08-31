# TP 11 — Terraform : déployer dans les réseaux SDN 🤖

⏱️ **1 h 30** · Jour 3

Objectif : décrire une infrastructure en code, la déployer, la modifier, la détruire.
Trois VM (Debian, Ubuntu, Rocky) et un conteneur Alpine, réparties dans les VNets
`vint` et `vdmz` du TP 08 — sans un seul clic.

📖 Provider : <https://registry.terraform.io/providers/bpg/proxmox/latest/docs>

---

## 1. Pourquoi Terraform et pas un script bash ? 🧠

```
   SCRIPT BASH                        TERRAFORM
   ───────────                        ─────────
   « fais ceci, puis cela »           « voici l'état que je veux »
   impératif                          déclaratif
   relancer = doublons ou erreurs     relancer = rien ne bouge (idempotent)
   supprimer = script inverse         terraform destroy
   « qu'est-ce qui tourne ? » → ???   terraform state list
   revue de code difficile            terraform plan = la diff, avant d'agir
```

Le cœur du système est le **state** : Terraform mémorise ce qu'il a créé et calcule la
différence entre l'état réel et l'état souhaité.

```
   main.tf  (souhaité)  ──┐
                          ├──►  terraform plan  ──►  diff  ──► apply
   terraform.tfstate ─────┘                                     │
        (réel)              ◄──────── mise à jour ──────────────┘
```

> 🪤 Le fichier `terraform.tfstate` **contient des secrets** (mots de passe cloud-init,
> hash…). Il ne va **jamais** dans Git. Le `.gitignore` du dépôt s'en charge.

---

## 2. Préparer le poste 💻

```bash
cd ~/ProxmoxFormation/lab/terraform/01-premiere-vm
source ~/.config/pve/token.env      # créé au TP 06

cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

Renseignez :

```hcl
pve_endpoint  = "https://192.168.50.13:8006/"     # VOTRE nœud
pve_api_token = "terraform@pve!tf=xxxxxxxx-...."  # VOTRE token
pve_node      = "pve3"
eleve         = 3
ssh_public_key = "ssh-ed25519 AAAA... eleve3@formation"
```

```bash
terraform init
terraform providers
```

---

## 3. Anatomie de la stack 📄

### `versions.tf` — épingler les versions

```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
```

🪤 **Épinglez, ne minorez pas.** `>= 0.80` autoriserait Terraform à installer
n'importe quelle version ≥ 0.80 — y compris une antérieure aux ressources SDN
(`sdn_vnet`, `sdn_subnet`, `sdn_applier` n'existent qu'à partir de la **v0.84.0**),
et vous obtiendriez `Invalid resource type` au TP 12. `~> 0.111` verrouille la
version majeure.minor et n'autorise que les correctifs.

### `provider.tf` — se connecter

```hcl
provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = true          # certificat auto-signé du lab

  ssh {
    agent    = true
    username = "root"
  }
}
```

🧠 **Pourquoi un bloc `ssh` ?** L'API Proxmox ne permet pas de téléverser un
*snippet* cloud-init. Le provider passe donc par SCP pour ces opérations.
Sans clé SSH sur le nœud, la ressource `proxmox_virtual_environment_file`
en `snippets` échoue. Assurez-vous que `ssh root@192.168.50.1N` fonctionne sans
mot de passe.

### `main.tf` — une VM clonée depuis le template

```hcl
resource "proxmox_virtual_environment_vm" "web" {
  name      = "web01-e${var.eleve}"
  node_name = var.pve_node
  # ⚠ +21 et non +20 : le VMID N20 est déjà pris par app01, cloné à la main au TP 10.
  vm_id   = var.eleve * 100 + 21
  pool_id = "eleve${var.eleve}"
  tags    = ["terraform", "web", "eleve${var.eleve}"]

  clone {
    vm_id = var.template_debian # N90
    full  = false               # linked clone : rapide, mais NON migrable (TP 10 §5)
  }

  agent { enabled = true }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge   = "vint"          # le VNet SDN du TP 08
    model    = "virtio"
    mtu      = 1                # hérite du MTU du VNet
    firewall = true
  }

  initialization {
    # l'IPAM + dnsmasq du SDN font le travail : on demande simplement du DHCP
    ip_config { ipv4 { address = "dhcp" } }
    user_account {
      username = "eleve"
      keys     = [var.ssh_public_key]
    }
  }

  lifecycle {
    ignore_changes = [ initialization[0].user_account[0].password ]
  }
}
```

---

## 4. Le cycle complet 🔄

```bash
terraform fmt          # met en forme
terraform validate     # vérifie la syntaxe et les types
terraform plan         # LA commande à lire attentivement
```

Lisez le plan :

```
  + create          ← création
  ~ update in-place ← modification à chaud
-/+ destroy and then create (forces replacement)   ← ⚠️ DESTRUCTION
  - destroy
```

🪤 **Toujours chercher les `-/+`.** Certains attributs (le `vm_id`, le nœud, le template
source) forcent une recréation. En production, ça veut dire une interruption de service.

```bash
terraform apply        # tapez « yes »
terraform state list
terraform show
terraform output
```

Vérifiez côté Proxmox :

```bash
ssh root@192.168.50.1N 'qm list; qm config <vmid> | head -20'
```

Puis testez la VM :

```bash
# l'IP est distribuée par l'IPAM : on la récupère via l'agent
ssh root@$PVE_HOST "qm agent \$(qm list | awk '/web01/{print \$1}') network-get-interfaces" | jq -r '.[]|."ip-addresses"[]?|select(."ip-address-type"=="ipv4")|."ip-address"'
```

### Modifier

Changez `memory.dedicated` de 2048 à 4096 dans `main.tf`, puis :

```bash
terraform plan     # doit montrer un ~ update in-place
terraform apply
ssh eleve@10.$N.10.<ip> 'free -m'
```

### Détruire

```bash
terraform destroy
```

---

## 5. Le parc multi-OS 🐧🦎🪨🏔️

```bash
cd ~/ProxmoxFormation/lab/terraform/02-parc-multi-os
cp ../01-premiere-vm/terraform.tfvars .
terraform init && terraform plan
```

Cette stack utilise `for_each` sur une **map de machines** : ajouter une VM = ajouter
trois lignes de configuration.

```hcl
variable "machines" {
  type = map(object({
    template = string
    vnet     = string
    cores    = number
    memory   = number
    tags     = list(string)
  }))
  default = {
    "web01" = { template = "ubuntu", vnet = "vdmz", cores = 2, memory = 2048, tags = ["web", "dmz", "ubuntu"]      }
    "app01" = { template = "debian", vnet = "vint", cores = 2, memory = 2048, tags = ["app", "interne", "debian"]  }
    "db01"  = { template = "rocky",  vnet = "vint", cores = 2, memory = 3072, tags = ["db", "interne", "rocky"]    }
  }
}
```

```hcl
resource "proxmox_virtual_environment_vm" "parc" {
  for_each  = var.machines

  name      = "${each.key}-e${var.eleve}"
  node_name = var.pve_node
  # Un VMID déterministe et stable : la map est triée, donc l'ordre ne bouge pas
  # quand on ajoute une machine. Base à +22 pour ne heurter ni app01 (N20) ni
  # web01 (N21) de la stack précédente.
  vm_id   = var.eleve * 100 + 22 + index(sort(keys(var.machines)), each.key)
  pool_id = "eleve${var.eleve}"
  tags    = concat(["terraform", "eleve${var.eleve}"], each.value.tags)

  clone {
    vm_id = var.templates[each.value.template]
    full  = false
  }

  agent { enabled = true }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge   = each.value.vnet       # ← vint ou vdmz, selon la map
    model    = "virtio"
    mtu      = 1
    firewall = true
  }

  initialization {
    ip_config { ipv4 { address = "dhcp" } }

    user_account {
      username = "eleve"
      keys     = [var.ssh_public_key]
    }
  }
}
```

🪤 **En HCL, pas de virgule entre les attributs d'un bloc.** `cpu { cores = 2, type =
"..." }` ne compile pas : le séparateur est le **retour à la ligne**. C'est l'erreur
n°1 quand on vient du JSON ou du Python. Le réflexe qui l'attrape en une seconde :

```bash
terraform fmt          # reformate, et refuse de reformater ce qui ne parse pas
terraform validate     # puis vérifie les types et les arguments inconnus
```

🧠 **Les `tags` ne sont pas décoratifs.** Ils viennent de la map, ils partent dans
Proxmox, et au **TP 13** Ansible construira ses groupes d'inventaire à partir d'eux.
`web01` taguée `web` ⇒ elle recevra automatiquement le rôle `web`. La chaîne
Terraform → tag Proxmox → groupe Ansible → rôle est **le** fil rouge du jour 3.

```bash
terraform apply
terraform output -json ips | jq
```

### Le conteneur Alpine, en Terraform aussi

```hcl
resource "proxmox_virtual_environment_container" "alpine" {
  node_name = var.pve_node
  vm_id     = var.eleve * 100 + 15
  pool_id   = "eleve${var.eleve}"
  tags      = ["terraform", "lxc"]

  initialization {
    hostname = "ct-tf-e${var.eleve}"
    ip_config { ipv4 { address = "dhcp" } }

    # ⚠ La clé va sur ROOT du conteneur, pas sur « eleve ».
    #   C'est pour ça que les LXC Alpine ont leur playbook dédié au TP 13.
    user_account { keys = [var.ssh_public_key] }
  }

  network_interface {
    name     = "eth0"
    bridge   = "vdmz"
    firewall = true
  }

  operating_system {
    template_file_id = var.lxc_template     # ex. "local:vztmpl/alpine-3.22-..."
    type             = "alpine"
  }

  cpu { cores = 1 }

  memory {
    dedicated = 256
    swap      = 128
  }

  disk {
    datastore_id = "local-lvm"
    size         = 2
  }

  unprivileged  = true
  start_on_boot = true
}
```

---

## 6. cloud-init avancé : les snippets 📝

Le bloc `initialization` de Terraform couvre 80 % des besoins. Pour le reste
(paquets, fichiers, scripts), on écrit un vrai `user-data`.

`lab/cloud-init/user-data-web.yaml` :

```yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - nginx
  - qemu-guest-agent
  - curl

write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    content: |
      <!doctype html>
      <html><head><meta charset="utf-8"><title>Lab Proxmox</title></head>
      <body style="font-family:sans-serif;text-align:center;padding-top:8em">
        <h1>🚀 Déployé par Terraform + cloud-init</h1>
        <p>Hostname : <code>HOSTNAME_PLACEHOLDER</code></p>
      </body></html>

runcmd:
  - [ sed, -i, "s/HOSTNAME_PLACEHOLDER/$(hostname)/", /var/www/html/index.html ]
  - [ systemctl, enable, --now, nginx ]
  - [ systemctl, enable, --now, qemu-guest-agent ]

final_message: "☑ cloud-init terminé en $UPTIME secondes"
```

Côté Terraform :

```hcl
resource "proxmox_virtual_environment_file" "user_data_web" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.pve_node

  source_raw {
    file_name = "user-data-web-e${var.eleve}.yaml"
    data      = file("${path.module}/../../cloud-init/user-data-web.yaml")
  }
}

# dans la ressource VM :
initialization {
  user_data_file_id = proxmox_virtual_environment_file.user_data_web.id
  ...
}
```

🪤 **Trois pièges cloud-init** :
1. Le fichier **doit** commencer par `#cloud-config` (première ligne, sans espace).
2. Le YAML est strict : indentation à 2 espaces, pas de tabulation.
   Validez avec `cloud-init schema --config-file user-data-web.yaml --annotate`.
3. `user_data_file_id` **remplace** le `user_account` généré par Proxmox : si vous
   voulez toujours votre clé SSH, remettez-la dans le YAML (`ssh_authorized_keys`).

Test :

```bash
terraform apply
sleep 60
curl http://10.$N.20.<ip-web01>/     # depuis srv01, autorisé par le TP 09
```

---

## 7. Bonnes pratiques 🎓

| Pratique | Pourquoi |
|---|---|
| `terraform fmt` avant chaque commit | Diffs lisibles |
| Épingler la version du provider | Une montée de version peut changer un comportement |
| `.gitignore` : `*.tfstate*`, `.terraform/`, `*.tfvars` | Secrets et binaires hors du dépôt |
| **Committer `.terraform.lock.hcl`** | Même provider, mêmes sommes, pour tout le monde |
| Un `tfvars` par environnement | `dev.tfvars`, `prod.tfvars` |
| `terraform plan -out=tf.plan` puis `apply tf.plan` | Ce qu'on applique est exactement ce qu'on a relu |
| `lifecycle { prevent_destroy = true }` sur le critique | Filet de sécurité |
| Backend distant (S3, Postgres, Terraform Cloud) | Travail à plusieurs sans écraser le state |

Le `.gitignore` fourni :

```
.terraform/          # les binaires téléchargés
*.tfstate            # 🔴 contient des secrets
*.tfstate.*
*.tfvars             # 🔴 contient votre token
!*.tfvars.example
tf.plan
crash.log
```

🪤 **`.terraform.lock.hcl`, lui, se COMMIT.** C'est une erreur classique de le mettre
dans le `.gitignore` : ce fichier fige la version exacte du provider **et ses sommes
de contrôle**. Sans lui, `terraform init` peut installer une version différente chez
chaque élève — exactement le problème que l'épinglage `~> 0.111` cherche à éviter.

```
   versions.tf          « je veux du ~> 0.111 »        ← l'intention
   .terraform.lock.hcl  « c'est 0.111.1, sha256:… »    ← le fait, reproductible
```

🪤 **Un lock généré sur un Mac ne suffit pas à une salle sous Linux.** Le fichier
enregistre un hash `h1:` **par plateforme** : si vous ne verrouillez que la vôtre,
le premier `terraform init` de chaque élève modifiera le fichier — donc un `git diff`
parasite chez tout le monde. Verrouillez explicitement les plateformes visées :

```bash
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=darwin_amd64
```

C'est exactement ce qui a été fait dans ce dépôt : vos `init` ne toucheront pas au
lock.

---

## 8. Quand ça casse 🔧

```bash
export TF_LOG=DEBUG          # très verbeux, mais on voit les appels API
terraform apply 2>&1 | tee /tmp/tf.log
unset TF_LOG

# La VM a été supprimée à la main dans l'UI ?
terraform state list
terraform state rm proxmox_virtual_environment_vm.web
terraform apply

# Importer une VM existante dans le state
terraform import proxmox_virtual_environment_vm.web pve3/320
```

| Erreur | Cause | Solution |
|---|---|---|
| `401 authentication failure` | Format du token | `user@realm!tokenid=secret` |
| `403 Permission check failed` | Rôle incomplet | Ajouter le privilège manquant au rôle `TerraformProv` |
| `unable to parse directory volume name` | Snippet sans SSH | Vérifier le bloc `ssh` du provider et `ssh root@node` |
| `VM <id> already exists` | Conflit de VMID | Respecter le plan de VMID (TP 00) |
| `timeout while waiting for agent` | Agent absent dans le template | Réinstaller le template avec `qemu-guest-agent` |
| Le clone reste bloqué | Template sur un stockage sans COW | `full = true` |
| `Invalid resource type: ..._sdn_vnet` | Provider < 0.84.0 | Épingler `~> 0.111`, `terraform init -upgrade` |
| `Missing newline after argument` | Virgule entre attributs d'un bloc HCL | `terraform fmt` |
| `can't migrate ... as it's a clone of ...` | Linked clone sur stockage local | `full = true`, ou `qm move-disk` vers Ceph |

---

## ✅ Checklist de validation

- [ ] `terraform apply` crée 3 VM et 1 conteneur
- [ ] Les 4 machines sont joignables en SSH par clé
- [ ] `curl http://<ip-web01>/` renvoie la page cloud-init
- [ ] `terraform plan` après `apply` affiche « No changes »
- [ ] Une modification de RAM produit un `~ update in-place` et s'applique à chaud
- [ ] `terraform destroy` nettoie tout, `qm list` ne montre plus que les templates
- [ ] Je sais lire un plan et repérer un `-/+` (recréation)
- [ ] `terraform fmt && terraform validate` passent sans rien signaler

---

## 🎁 Bonus

1. Écrivez un **module** local `modules/vm/` et appelez-le trois fois. Comparez la
   lisibilité avec le `for_each`.
2. Ajoutez un `output` qui interroge l'agent QEMU pour renvoyer les IP réelles
   (`proxmox_virtual_environment_vm.parc[*].ipv4_addresses`).
3. Enchaînez avec **Ansible** : générez un inventaire depuis les outputs Terraform
   (`terraform output -json | jq -r ...`) et jouez un playbook qui déploie une appli.

➡️ Suite : [TP 12 — Terraform : un 3ᵉ LAN et ses règles](12-terraform-sdn-troisieme-lan.md)
