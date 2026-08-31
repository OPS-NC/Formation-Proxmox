# Stacks Terraform de la formation

Trois stacks progressives. Chacune est autonome et se déroule avec
`init → plan → apply → destroy`.

| Stack | TP | Ce qu'elle fait |
|---|---|---|
| `01-premiere-vm/` | 11 | Une VM clonée d'un template, dans le VNet `vint` |
| `02-parc-multi-os/` | 11 | 3 VM (Debian/Ubuntu/Rocky) + 1 LXC, réparties dans `vint`/`vdmz`, avec des tags |
| `03-sdn-troisieme-lan/` | 12 | Une zone SDN complète + ses règles de firewall + 2 guests |

> Le serveur NFS du TP 14 n'est pas une VM : c'est **votre poste Ubuntu**, configuré par
> Ansible (`lab/ansible/nfs-local.yml`). Il n'y a donc pas de stack Terraform pour lui.

## Prérequis

```bash
source ~/.config/pve/token.env        # créé au TP 06
cp 01-premiere-vm/terraform.tfvars.example 01-premiere-vm/terraform.tfvars
vim 01-premiere-vm/terraform.tfvars   # renseignez VOS valeurs
```

Le token doit avoir le rôle `TerraformProv` (TP 06 §7), et
`ssh root@<votre-noeud>` doit fonctionner **sans mot de passe** — le provider passe
par SCP pour déposer les snippets cloud-init.

## Le cycle

```bash
cd 01-premiere-vm
terraform init
terraform fmt && terraform validate
terraform plan -out=tf.plan      # ⭐ à LIRE, en particulier les -/+ (recréation)
terraform apply tf.plan
terraform output
terraform destroy
```

## Conventions

- Un `terraform.tfvars` par élève, **jamais commité**
- Les VMID sont calculés depuis `var.eleve` : aucun conflit entre élèves
- Les tags posés ici pilotent l'inventaire Ansible du TP 13
- Tous les disques vont sur **`local-lvm`** (LVM-thin). Pas de ZFS dans cette formation
- `mtu = 1` sur toutes les cartes réseau : indispensable en EVPN (jour 4)
- Provider épinglé en `~> 0.111` : les ressources SDN `vnet`/`subnet`/`applier`
  n'existent qu'à partir de **v0.84.0** du provider `bpg/proxmox`
- Les clones sont **liés** (`full = false`) : rapide, mais **non migrable** entre
  nœuds tant que le disque est sur `local-lvm` (voir TP 10 §5 et TP 19)

## Erreurs fréquentes

| Erreur | Cause |
|---|---|
| `401 authentication failure` | Format du token : `user@realm!tokenid=secret` |
| `403 Permission check failed` | Privilège manquant dans le rôle |
| `unable to parse directory volume name` | Bloc `ssh` absent, ou SSH par clé non fonctionnel |
| `bridge 'X' does not exist` | Il manque un `depends_on` sur `proxmox_sdn_applier.apply` |
| `An argument named "subnet" is not expected here` | Le subnet SDN s'appelle `cidr` dans le provider (`--subnet` côté `pvesh` seulement) |
| `Blocks of type "dhcp_range" are not expected here` | `dhcp_range` est un **attribut** : `dhcp_range = { ... }` |
| `Invalid resource type: proxmox_sdn_vnet` | Provider < 0.84.0 — `terraform init -upgrade` |
| `can't migrate ... as it's a clone of ...` | Linked clone sur stockage local : `full = true`, ou déplacer le disque sur Ceph |
| `VM already exists` | Plan de VMID non respecté |
