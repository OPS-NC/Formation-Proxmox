# Stacks Terraform de la formation

Quatre stacks progressives. Chacune est autonome et se déroule avec
`init → plan → apply → destroy`.

| Stack | TP | Ce qu'elle fait |
|---|---|---|
| `01-premiere-vm/` | 11 | Une VM clonée d'un template, dans le VNet `vint` |
| `02-parc-multi-os/` | 11 | 3 VM (Debian/Ubuntu/Rocky) + 1 LXC, réparties dans `vint`/`vdmz`, avec des tags |
| `03-sdn-troisieme-lan/` | 12 | Une zone SDN complète + ses règles de firewall + 2 guests |
| `04-nfs/` | 14 | La VM serveur NFS et son disque de données |

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
- `mtu = 1` sur toutes les cartes réseau : indispensable en EVPN (jour 4)

## Erreurs fréquentes

| Erreur | Cause |
|---|---|
| `401 authentication failure` | Format du token : `user@realm!tokenid=secret` |
| `403 Permission check failed` | Privilège manquant dans le rôle |
| `unable to parse directory volume name` | Bloc `ssh` absent, ou SSH par clé non fonctionnel |
| `bridge 'X' does not exist` | Il manque un `depends_on` sur l'apply SDN |
| `VM already exists` | Plan de VMID non respecté |
