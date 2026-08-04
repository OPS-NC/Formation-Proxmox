# Ansible — inventaire dynamique Proxmox et rôles par tags

Support des **TP 13** et **14**.

## L'idée en une phrase

Un **tag** posé sur une VM dans Proxmox devient un **groupe** Ansible, qui
déclenche un **rôle**. Aucun inventaire à maintenir à la main.

```
  Terraform            Proxmox              Ansible              Résultat
  ─────────            ───────              ───────              ────────
  tags = ["web"]  ──►  tag « web »  ──►  groupe proxmox_web  ──►  rôle web
  tags = ["db"]   ──►  tag « db »   ──►  groupe proxmox_db   ──►  rôle db
```

Et le rôle `nfs` s'applique à votre **poste de travail** (TP 14), via un inventaire
statique — même rôle, autre cible.

## Installation

```bash
sudo apt install -y ansible python3-proxmoxer python3-requests
ansible-galaxy collection install community.general ansible.posix community.postgresql
```

## Configuration

1. Créez le token de lecture (TP 06 §7.2) :
   ```bash
   pveum user add ansible@pve
   pveum aclmod / --users ansible@pve --roles PVEAuditor
   pveum user token add ansible@pve inv --privsep 0
   ```
2. Renseignez `~/.config/pve/token.env` :
   ```bash
   export PVE_ANSIBLE_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```
3. Adaptez `inventory/proxmox.yml` (l'URL de votre nœud) et
   `group_vars/all.yml` (`pve_host` et `eleve`).

## Utilisation

```bash
source ~/.config/pve/token.env

ansible-inventory --graph              # les groupes construits depuis les tags
ansible-inventory --host web01-e3 | jq # toutes les variables d'un hôte
ansible linux -m ping                  # test de connectivité

ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook site.yml --limit proxmox_web
```

## Le rebond SSH

Les VM sont dans les VNets `10.N.x.0/24`, derrière le NAT du nœud : votre PC ne
les joint pas directement. `group_vars/all.yml` configure donc le nœud Proxmox
comme **bastion** :

```yaml
ansible_ssh_common_args: >-
  -o ProxyCommand="ssh -W %h:%p -q root@{{ pve_host }}"
```

C'est exactement ce qu'on fait en production. Vérifiez d'abord que
`ssh root@<votre-noeud>` fonctionne sans mot de passe.

## Le critère de qualité 🎯

```bash
ansible-playbook site.yml     # premier passage : des « changed »
ansible-playbook site.yml     # second passage  : changed=0 PARTOUT
```

Si une tâche reste en `changed` à chaque exécution, elle est mal écrite
(typiquement un `command` sans `creates:` ni `changed_when:`). Corrigez-la : un
playbook qui ment sur ce qu'il change devient inutilisable pour détecter les
dérives de configuration.

## Structure

```
ansible/
├── ansible.cfg
├── inventory/proxmox.yml       ← ★ l'inventaire dynamique
├── inventory/local.yml         ← inventaire statique : votre poste (TP 14)
├── group_vars/
│   ├── all.yml                 rebond SSH, variables globales
│   ├── proxmox_web.yml         variables du groupe « web »
│   └── proxmox_db.yml          variables du groupe « db »
├── roles/
│   ├── common/    socle : paquets, motd, SSH durci, node_exporter
│   ├── web/       nginx + vhost + page générée
│   ├── db/        PostgreSQL, multi-OS (Debian ET Rocky)
│   └── nfs/       serveur NFS + exports  (disque optionnel)
├── site.yml       le parc Proxmox
├── nfs-local.yml  ← le serveur NFS sur votre poste (TP 14)
└── ping.yml       test de connectivité
```

## Le cas particulier du rôle `nfs`

```bash
# Sur votre poste, pas sur une VM
ansible-playbook -i inventory/local.yml nfs-local.yml --ask-become-pass
```

`nfs_manage_disk: false` saute les tâches de partitionnement : on expose simplement un
répertoire existant. Avec `true` et un `nfs_device`, le même rôle prépare un disque
dédié. **Un rôle, deux contextes** — c'est le signe qu'il est bien écrit.

## Secrets

```bash
# Chiffrer une valeur
ansible-vault encrypt_string 'MonMotDePasse' --name 'db_password'

# Chiffrer un fichier entier
ansible-vault encrypt group_vars/proxmox_db.yml

# Jouer avec
ansible-playbook site.yml --ask-vault-pass
```

## Dépannage

| Symptôme | Solution |
|---|---|
| `Invalid data from server` | `apt install python3-proxmoxer` |
| Inventaire vide | Vérifiez le token, `validate_certs: false`, videz `/tmp/ansible-pve-cache` |
| `ansible_host` absent | L'agent QEMU ne tourne pas dans la VM |
| `UNREACHABLE` | Le `ProxyCommand` n'est pas configuré, ou `ssh root@node` échoue |
| `changed` à chaque fois | Tâche non idempotente |

```bash
rm -rf /tmp/ansible-pve-cache        # ⭐ le réflexe après un changement de tag
ansible-inventory --graph
ansible all -m ping -vvv
```

## Qualité

```bash
pipx install ansible-lint && ansible-lint
```
