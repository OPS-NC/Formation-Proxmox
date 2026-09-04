# TP 13 — Ansible : inventaire dynamique Proxmox et rôles par tags 🎼

⏱️ **1 h 15** · Jour 3

Objectif : Terraform crée les machines, Ansible les configure. Il interroge l'API
Proxmox, lit les tags posés au TP 11 et applique le rôle correspondant. Aucun
inventaire à maintenir à la main.

📖 Plugin d'inventaire : <https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_inventory.html>

> ⚠️ **Prérequis** : la stack Terraform `02-parc-multi-os` (TP 11) doit être **appliquée** —
> `web01`, `app01`, `db01` et `ct-cache` tournent. Si vous l'aviez détruite en fin de
> TP 11, relancez `terraform apply` dans `lab/terraform/02-parc-multi-os/` avant de
> commencer.

---

## 1. Terraform et Ansible : qui fait quoi ? 🧠

```
   ┌──────────────────┐                    ┌──────────────────┐
   │    TERRAFORM     │                    │     ANSIBLE      │
   │                  │                    │                  │
   │  CRÉE l'objet    │ ────────────────►  │ CONFIGURE ce qui │
   │  · la VM         │   les machines     │ tourne dedans    │
   │  · le disque     │   existent         │  · paquets       │
   │  · le réseau     │                    │  · fichiers      │
   │  · le firewall   │                    │  · services      │
   │                  │                    │  · utilisateurs  │
   │  déclaratif      │                    │  déclaratif      │
   │  état = tfstate  │                    │  état = la machine│
   └──────────────────┘                    └──────────────────┘
        « day 0 »                              « day 1 → n »
```

🧠 Terraform s'arrête quand la machine démarre ; l'intérieur du système, c'est
Ansible. cloud-init pourrait tout faire, mais il ne s'exécute qu'une fois : il ne
remet pas en conformité une machine qui a dérivé. Ansible, si.

---

## 2. Le fil rouge : le tag 🏷️

```
   TP 11               Proxmox                TP 13                TP 13
   ─────               ───────                ─────                ─────
   tags = ["web"] ──► tag "web" sur ──► groupe Ansible ──► rôle « web »
                       la VM web01        proxmox_web            appliqué
                                             │
   tags = ["db"]  ──► tag "db"  ──► groupe proxmox_db ──► rôle « db »
```

Un tag posé dans Terraform pilote un rôle Ansible. Traçable, et ça tient dans une
revue de code.

---

## 3. Installer Ansible 💻

Sur votre **PC Ubuntu** :

```bash
sudo apt update
sudo apt install -y ansible python3-proxmoxer python3-requests
ansible --version
ansible-galaxy collection install community.general ansible.posix \
                                 community.proxmox community.postgresql
ansible-galaxy collection list | grep -E 'community.proxmox|community.general|ansible.posix'
```

🪤 **Deux prérequis, deux erreurs très différentes :**

| Manquant | Symptôme |
|---|---|
| `python3-proxmoxer` (côté contrôleur) | `Invalid data from server` |
| collection `community.proxmox` | inventaire **vide**, ou `Attempting to use a plugin that has been removed` |

🧠 **`community.proxmox` et non `community.general.proxmox`** : le plugin a
déménagé. `community.general.proxmox` n'est plus qu'une redirection, supprimée en
`community.general` 15.0.0. Les collections fourre-tout se scindent par domaine :
quand un plugin râle, vérifiez d'abord s'il n'a pas changé de collection.

---

## 4. La structure du dépôt Ansible 📁

```
lab/ansible/
├── ansible.cfg
├── inventory/
│   ├── proxmox.yml           ← ★ l'inventaire dynamique
│   └── local.yml             ← inventaire statique : votre poste (TP 14)
├── group_vars/
│   ├── all.yml               options SSH, variables globales
│   ├── proxmox_web.yml       variables du groupe « web »
│   └── proxmox_db.yml        variables du groupe « db »
├── roles/
│   ├── common/               ← appliqué aux VM Terraform
│   │   ├── defaults/main.yml
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   └── templates/motd.j2
│   ├── web/                  ← machines taguées « web »
│   │   ├── defaults/main.yml
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   └── templates/{index.html.j2,site.conf.j2}
│   ├── db/                   ← machines taguées « db »
│   │   ├── defaults/main.yml
│   │   ├── tasks/main.yml
│   │   └── handlers/main.yml
│   └── nfs/                  ← serveur NFS sur votre poste (TP 14)
│       ├── defaults/main.yml
│       ├── tasks/main.yml
│       ├── handlers/main.yml
│       └── templates/exports.j2
├── site.yml                  ← le playbook principal (les VM)
├── alpine.yml                ← amorçage des LXC Alpine (module raw)
├── nfs-local.yml             ← le serveur NFS sur votre poste (TP 14)
└── ping.yml                  ← test de connectivité
```

> Les extraits de rôles de ce TP sont abrégés. Le code complet (retries, sudoers,
> `nginx -t`, `flush_handlers`, `no_log`…) est dans `lab/ansible/roles/`, qui fait foi.

```bash
cd ~/ProxmoxFormation/lab/ansible
ls -R | head -40
```

---

## 5. L'inventaire dynamique ⭐

`inventory/proxmox.yml` :

```yaml
---
plugin: community.proxmox.proxmox     # ⚠ PAS community.general.proxmox (déprécié)
url: "https://172.30.30.151:8006"          # ⚠ l'IP de VOTRE nœud ($PVE)
user: ansible@pve
token_id: inv
token_secret: "{{ lookup('env', 'PVE_ANSIBLE_TOKEN_SECRET') }}"
validate_certs: false

# Les IP viennent de l'agent QEMU (VM) ou de l'API LXC : il faut les facts,
# et un guest DÉMARRÉ
want_facts: true
qemu_extended_statuses: true

# Les groupes construits automatiquement
keyed_groups:
  # un groupe par tag Proxmox   →  proxmox_web, proxmox_db, proxmox_interne…
  - key: proxmox_tags_parsed
    separator: "_"
    prefix: proxmox
  # un groupe par nœud          →  node_pve (jours 1-3), node_pve3… en cluster
  - key: proxmox_node
    prefix: node
  # un groupe par pool          →  pool_lab
  - key: proxmox_pool
    prefix: pool

groups:
  # ⭐ « linux » = les VM déployées par Terraform (tag « terraform »), celles que
  #   cloud-init a préparées pour Ansible (compte eleve + clé). Les machines faites à
  #   la main (srv01, cloud01, win01, pbs) n'y sont pas — elles restent dans leurs
  #   groupes par tag (proxmox_web…) si on leur en pose un.
  linux: >-
    proxmox_vmtype == 'qemu' and
    'terraform' in (proxmox_tags | default(''))
  conteneurs: "proxmox_vmtype == 'lxc'"
  windows: "'windows' in (proxmox_tags | default(''))"

# L'IP de connexion : DEUX sources selon le type de guest
compose:
  ansible_host: >-
    (
      (proxmox_agent_interfaces | default([])
        | rejectattr('name', 'eq', 'lo')
        | map(attribute='ip-addresses') | flatten
        | selectattr('ip-address-type', 'eq', 'ipv4')
        | map(attribute='ip-address') | list)
      +
      (proxmox_lxc_interfaces | default([])
        | rejectattr('name', 'eq', 'lo')
        | selectattr('inet', 'defined')
        | map(attribute='inet')
        | map('regex_replace', '/.*$', '') | list)
    ) | first | default(proxmox_name)

cache: true
cache_plugin: jsonfile
cache_timeout: 120
cache_connection: /tmp/ansible-pve-cache
```

🧠 **`keyed_groups` + `proxmox_tags_parsed`** fait tout le travail : chaque tag
Proxmox devient un groupe Ansible préfixé `proxmox_`. Un tag ajouté dans l'interface,
un groupe à la prochaine exécution.

🧠 **`linux` ne contient que les VM taguées `terraform`** : les seules qu'Ansible joint
sans préparation, cloud-init y ayant créé le compte `eleve` avec votre clé. `srv01`
(mot de passe seulement), `win01`, `cloud01` (120) ou `pbs` (901) remonteraient en
`UNREACHABLE` à chaque `PLAY RECAP`. Un tag de rôle (`web`, `db`) les fait entrer dans
`proxmox_web` / `proxmox_db` — voir §11.

### Tester l'inventaire

```bash
cd ~/ProxmoxFormation/lab/ansible
source ~/.config/pve/token.env

ansible-inventory -i inventory/proxmox.yml --graph
```

Sortie attendue (extrait — vos guests manuels `srv01`, `win01`, `cloud01`, `pbs` et
les CT apparaissent aussi dans `proxmox_all_qemu` / `proxmox_all_lxc` et leurs groupes
par tag) :

```
@all:
  |--@ungrouped:
  |--@linux:
  |  |--web01
  |  |--app01
  |  |--db01
  |--@proxmox_web:
  |  |--web01
  |--@proxmox_db:
  |  |--db01
  |--@proxmox_interne:
  |  |--app01
  |  |--db01
  |--@node_pve:
  |  |--web01
  |  |--app01
  |  |--db01
  |--@pool_lab:
  |  |--web01
  |  |--app01
  |  |--db01
```

```bash
# Le détail d'un hôte
ansible-inventory -i inventory/proxmox.yml --host web01 | jq

# Toutes les variables disponibles
ansible-inventory -i inventory/proxmox.yml --list | jq '._meta.hostvars | keys'
```

🪤 **Une VM sans agent QEMU n'aura pas d'`ansible_host`.** Vérifiez que
`qemu-guest-agent` tourne sur vos VM (il est dans les templates du TP 10).

🧠 **Les conteneurs LXC** n'ont pas d'agent QEMU (ils partagent le noyau de l'hôte).
Proxmox connaît leurs adresses par l'API `/nodes/<nœud>/lxc/<id>/interfaces`, exposée
par le plugin dans une autre variable, `proxmox_lxc_interfaces`, avec une autre
structure :

| Type | Variable | Champ de l'IP | Format |
|---|---|---|---|
| VM QEMU | `proxmox_agent_interfaces` | `ip-addresses[].ip-address` | `10.10.20.104` |
| LXC | `proxmox_lxc_interfaces` | `inet` | `10.10.20.117/24` ⚠️ **avec le masque** |

D'où le `regex_replace('/.*$', '')` qui retire le `/24`, et la concaténation des deux
listes. Sans la branche LXC, `ansible_host` retombe sur `proxmox_name`, le nom du
conteneur, que rien ne résout : `UNREACHABLE`.

Les deux exigent `want_facts: true` **et** un guest démarré.

```bash
# Vérifier ce que l'inventaire a réellement trouvé
ansible-inventory --host ct-cache | jq '.ansible_host, .proxmox_lxc_interfaces'
ansible-inventory --host web01    | jq '.ansible_host, .proxmox_agent_interfaces'
```

---

## 6. `ansible.cfg` et la connexion 🔌

```ini
[defaults]
inventory              = inventory/proxmox.yml
host_key_checking      = False
remote_user            = eleve
private_key_file       = ~/.ssh/id_ed25519
interpreter_python     = auto_silent
# ⚠ « stdout_callback = yaml » (community.general) a été SUPPRIMÉ en
#   community.general 12.0.0. Le rendu YAML est désormais une option du
#   callback « default » d'ansible-core, depuis la 2.13.
stdout_callback        = default
callback_result_format = yaml
callbacks_enabled      = ansible.posix.profile_tasks
retry_files_enabled    = False
forks                  = 10
timeout                = 30
roles_path             = roles

[privilege_escalation]
become                 = True
become_method          = sudo
become_user            = root
become_ask_pass        = False

[ssh_connection]
pipelining             = True
ssh_args               = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
```

🪤 **`stdout_callback = yaml` ne marche plus** : retiré de `community.general`,
Ansible refuse de démarrer. Le rendu YAML est une option du callback `default`.

### Joindre les VM : la route du TP 07 ⭐

Vos VM sont dans les VNets `10.10.x.0/24`, derrière votre nœud. La route posée au
TP 07 doit être encore là :

```bash
PVE=172.30.30.___          # ⚠ l'IP de VOTRE nœud
ip route | grep 10.10.0.0 || sudo ip route add 10.10.0.0/16 via $PVE
ssh eleve@10.10.20.<ip-web01> hostname      # ✅ direct
```

Le PC joint les VM directement, sans bastion ni `ProxyCommand`. `group_vars/all.yml`
ne porte que les options SSH communes :

```yaml
---
ansible_ssh_common_args: >-
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
```

🧠 Les clés d'hôte des VM changent à chaque `terraform destroy/apply` : on ne les
épingle pas. En production, on les gérerait (SSH CA, ou inventaire des empreintes).

⚠️ Le firewall du nœud doit laisser passer le forward LAN → VNets vers les ports
qu'Ansible utilise (SSH) — c'est l'affaire des règles du TP 09.

### Vérifier

```bash
ansible -i inventory/proxmox.yml linux -m ping
ansible -i inventory/proxmox.yml linux -m setup -a 'filter=ansible_distribution*'
```

✅ Vous devez obtenir des `pong` de toutes vos VM Terraform (`web01`, `app01`, `db01`).

---

## 7. Rôle n°1 : `common` (appliqué partout) 🧰

`roles/common/tasks/main.yml` :

```yaml
---
- name: Détecter le gestionnaire de paquets
  ansible.builtin.debug:
    msg: "{{ ansible_distribution }} {{ ansible_distribution_version }} — {{ ansible_pkg_mgr }}"

- name: Installer les paquets de base
  ansible.builtin.package:
    name: "{{ common_packages }}"
    state: present
  retries: 3
  delay: 5

- name: Fuseau horaire
  community.general.timezone:
    name: "{{ common_timezone }}"

- name: Bannière de connexion
  ansible.builtin.template:
    src: motd.j2
    dest: /etc/motd
    mode: "0644"

- name: Compte d'administration
  ansible.builtin.user:
    name: "{{ common_admin_user }}"
    groups: "{{ 'sudo' if ansible_os_family == 'Debian' else 'wheel' }}"
    append: true
    shell: /bin/bash
    state: present

- name: Clé SSH de l'administrateur
  ansible.posix.authorized_key:
    user: "{{ common_admin_user }}"
    key: "{{ lookup('file', lookup('env','HOME') + '/.ssh/id_ed25519.pub') }}"
    state: present

- name: Durcissement SSH — pas de mot de passe
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PasswordAuthentication'
    line: 'PasswordAuthentication no'
    validate: 'sshd -t -f %s'
  notify: redemarrer ssh

- name: Exporteur de métriques
  ansible.builtin.package:
    name: prometheus-node-exporter
    state: present
  when: ansible_os_family == 'Debian'
  notify: activer node-exporter
```

`roles/common/handlers/main.yml` :

```yaml
---
- name: redemarrer ssh
  ansible.builtin.service:
    name: "{{ 'ssh' if ansible_os_family == 'Debian' else 'sshd' }}"
    state: restarted

- name: activer node-exporter
  ansible.builtin.service:
    name: prometheus-node-exporter
    state: started
    enabled: true
```

`roles/common/templates/motd.j2` :

```
╔══════════════════════════════════════════════════════════════╗
║  {{ inventory_hostname.ljust(58) }}║
║  {{ (ansible_distribution + ' ' + ansible_distribution_version).ljust(58) }}║
║  Géré par Ansible — toute modification manuelle sera écrasée ║
║  Rôles : {{ (group_names | join(', '))[:50].ljust(52) }}║
╚══════════════════════════════════════════════════════════════╝
```

`group_vars/all.yml` (suite du fichier, après les options SSH du §6) :

```yaml
# ── Rôle common ──
common_timezone: "Pacific/Noumea"
common_admin_user: "eleve"
common_packages:
  - curl
  - vim
  - htop
  - git
  - rsync
  - ca-certificates
```

🧠 **Le rôle est multi-OS.** `ansible.builtin.package` s'adapte à `apt` ou `dnf`,
`ansible_os_family` gère les différences Debian/RedHat. Le Rocky du parc est là pour
ça : du code portable, pas des `apt install` empilés.

---

## 8. Rôle n°2 : `web` (machines taguées `web`) 🌍

`roles/web/tasks/main.yml` :

```yaml
---
- name: Installer nginx
  ansible.builtin.package:
    name: nginx
    state: present

- name: Répertoire racine
  ansible.builtin.file:
    path: "{{ web_root }}"
    state: directory
    mode: "0755"

- name: Page d'accueil
  ansible.builtin.template:
    src: index.html.j2
    dest: "{{ web_root }}/index.html"
    mode: "0644"
  notify: recharger nginx

- name: Configuration du vhost
  ansible.builtin.template:
    src: site.conf.j2
    dest: "{{ web_conf_dir }}/lab.conf"
    mode: "0644"
  notify: recharger nginx

- name: Démarrer et activer nginx
  ansible.builtin.service:
    name: nginx
    state: started
    enabled: true

- name: Vérifier que le service répond
  ansible.builtin.uri:
    url: "http://localhost/"
    status_code: 200
    return_content: true
  register: page
  retries: 5
  delay: 2

- name: Afficher le titre servi
  ansible.builtin.debug:
    msg: "{{ page.content | regex_search('<h1>(.*)</h1>', '\\1') | first }}"
```

`roles/web/templates/index.html.j2` :

```html
<!doctype html>
<html lang="fr">
<head><meta charset="utf-8"><title>{{ inventory_hostname }}</title>
<style>body{font-family:system-ui;text-align:center;padding-top:6em;background:#111;color:#eee}
code{background:#222;padding:.2em .5em;border-radius:4px}</style></head>
<body>
  <h1>🌍 {{ inventory_hostname }}</h1>
  <p>OS : <code>{{ ansible_distribution }} {{ ansible_distribution_version }}</code></p>
  <p>IP : <code>{{ ansible_default_ipv4.address }}</code></p>
  <p>Nœud Proxmox : <code>{{ proxmox_node | default('?') }}</code></p>
  <p>Groupes Ansible : <code>{{ group_names | join(' · ') }}</code></p>
  <p>{{ ansible_managed }}</p>   {# ⚠ surtout PAS d'horodatage ici — voir §10 #}
</body></html>
```

`group_vars/proxmox_web.yml` :

```yaml
---
web_root: "{{ '/var/www/html' if ansible_os_family == 'Debian' else '/usr/share/nginx/html' }}"
web_conf_dir: "{{ '/etc/nginx/sites-enabled' if ansible_os_family == 'Debian' else '/etc/nginx/conf.d' }}"
```

---

## 9. Rôle n°3 : `db` (machines taguées `db`) 🗄️

`roles/db/tasks/main.yml` :

```yaml
---
- name: Installer PostgreSQL (Debian/Ubuntu)
  ansible.builtin.apt:
    name: [postgresql, python3-psycopg2]
    state: present
  when: ansible_os_family == 'Debian'

- name: Installer PostgreSQL (RedHat/Rocky)
  when: ansible_os_family == 'RedHat'
  block:
    - name: Paquets
      ansible.builtin.dnf:
        name: [postgresql-server, python3-psycopg2]
        state: present

    - name: Initialiser le cluster
      ansible.builtin.command: postgresql-setup --initdb
      args:
        creates: /var/lib/pgsql/data/PG_VERSION

- name: Démarrer PostgreSQL
  ansible.builtin.service:
    name: postgresql
    state: started
    enabled: true

- name: Écoute sur le réseau interne
  ansible.builtin.lineinfile:
    path: "{{ db_conf_path }}"
    regexp: "^#?listen_addresses"
    line: "listen_addresses = '*'"
  notify: redemarrer postgresql

- name: Autoriser uniquement le réseau interne
  ansible.builtin.lineinfile:
    path: "{{ db_hba_path }}"
    line: "host  all  all  {{ db_allowed_network }}  scram-sha-256"
    state: present
  notify: redemarrer postgresql

- name: Créer la base applicative
  become_user: postgres
  community.postgresql.postgresql_db:
    name: "{{ db_name }}"
    state: present

- name: Créer l'utilisateur applicatif
  become_user: postgres
  community.postgresql.postgresql_user:
    name: "{{ db_user }}"
    password: "{{ db_password }}"
    db: "{{ db_name }}"
    priv: ALL
    state: present
```

`group_vars/proxmox_db.yml` :

```yaml
---
db_name: applab
db_user: applab
db_password: "Formation2026!"     # 🪤 en production : ansible-vault
db_allowed_network: "10.10.10.0/24"
db_conf_path: >-
  {{ '/etc/postgresql/17/main/postgresql.conf' if ansible_os_family == 'Debian'
     else '/var/lib/pgsql/data/postgresql.conf' }}
db_hba_path: >-
  {{ '/etc/postgresql/17/main/pg_hba.conf' if ansible_os_family == 'Debian'
     else '/var/lib/pgsql/data/pg_hba.conf' }}
```

🪤 **Pas de mot de passe en clair** :

```bash
ansible-vault encrypt_string 'Formation2026!' --name 'db_password' \
  >> group_vars/proxmox_db.yml
ansible-playbook site.yml --ask-vault-pass
```

---

## 10. Le playbook principal 🎬

`site.yml` :

```yaml
---
- name: Socle commun sur toutes les VM Linux
  hosts: linux          # ⚠ pas « linux:conteneurs » — voir l'encart ci-dessous
  become: true
  gather_facts: true
  roles:
    - common

- name: Serveurs web
  hosts: proxmox_web
  become: true
  roles:
    - web

- name: Serveurs de bases de données
  hosts: proxmox_db
  become: true
  roles:
    - db
```

🪤 **Les LXC Alpine ne sont pas dans `site.yml`** : Alpine n'embarque pas de Python,
dont Ansible a besoin sur la cible. Ni `bash`, ni `sudo`, et Terraform pose la clé SSH
sur `root`, pas sur `eleve`. Un playbook dédié, `alpine.yml`, les amorce avec le
module `raw`, le seul sans interpréteur :

```yaml
- name: Installer Python, bash et sudo (module raw — aucun Python requis)
  ansible.builtin.raw: |
    command -v python3 >/dev/null && command -v sudo >/dev/null && exit 0
    apk add --no-cache python3 bash sudo shadow
```

```bash
ansible-playbook alpine.yml     # amorce + socle sur les LXC
ansible-playbook site.yml       # les VM
```

🧠 Même besoin sur un switch, un routeur ou une image *distroless* : `raw` est la
réponse standard.

### Dérouler

```bash
cd ~/ProxmoxFormation/lab/ansible
source ~/.config/pve/token.env

# 1. Vérifier la syntaxe
ansible-playbook site.yml --syntax-check

# 2. Répétition générale : rien n'est modifié
ansible-playbook site.yml --check --diff

# 3. Pour de vrai
ansible-playbook site.yml

# 4. Une seule catégorie
ansible-playbook site.yml --limit proxmox_web
```

### La preuve de l'idempotence 🎯

```bash
ansible-playbook site.yml
```

Relancez immédiatement :

```
PLAY RECAP ****************************************************
web01     : ok=14  changed=0  unreachable=0  failed=0
app01     : ok=11  changed=0  unreachable=0  failed=0
db01      : ok=16  changed=0  unreachable=0  failed=0
```

🧠 **`changed=0` au second passage : le critère de qualité d'un playbook.** Une tâche
qui reste en `changed` est mal écrite (typiquement un `command` sans `creates:` ni
`changed_when:`). Un playbook qui ment sur ce qu'il change ne sert plus à détecter les
dérives.

🪤 **Le piège le plus courant : l'horodatage dans un template.**

```jinja
Déployé le {{ ansible_date_time.iso8601 }}     ← ❌ jamais
```

Le contenu change à chaque seconde : `template` réécrit le fichier et remonte
`changed` à chaque passage. Impossible alors de distinguer une dérive de l'horloge.

Mêmes effets avec `now()`, `lookup('pipe', 'date')`, un `lookup('password')` sans
fichier de stockage, un UUID aléatoire. Un fichier géré est une fonction pure de son
état désiré. Pour tracer un déploiement, un `lineinfile` dans `/var/log/` ; pour
signer un fichier généré, `{{ ansible_managed }}` est stable.

### Vérifier le résultat

```bash
# La page web générée
ssh eleve@10.10.20.<ip-web01> 'curl -s localhost | grep h1'

# La base
ssh eleve@10.10.10.<ip-db01> \
  'sudo -u postgres psql -c "\l" | grep applab'

# Le motd
ssh eleve@10.10.10.<ip-app01>
```

---

## 11. Le test qui boucle la boucle 🔁

Ajoutez le tag `web` à une machine hors du groupe `linux` : `cloud01`, clonée à la
main au TP 10 (VMID `120`).

```bash
PVE=172.30.30.___          # ⚠ l'IP de VOTRE nœud
ssh root@$PVE 'qm set 120 --tags "manuel,debian,interne,app,web"'
```

Puis, **sans toucher à l'inventaire** :

```bash
rm -rf /tmp/ansible-pve-cache          # on vide le cache
ansible-inventory -i inventory/proxmox.yml --graph | grep -A4 proxmox_web
ansible-playbook site.yml --limit proxmox_web
```

✅ `cloud01` apparaît dans `proxmox_web` et reçoit nginx. Elle n'est pas dans `linux`,
donc `common` ne l'a pas touchée : seul le tag a déclenché le rôle `web`.

```bash
ssh eleve@10.10.10.50 'curl -s localhost | grep h1'     # la page générée sur cloud01
```

🧠 Configuration pilotée par étiquette : le modèle de Kubernetes (labels/selectors)
et d'AWS (tags/ASG), en trente lignes de YAML sur Proxmox.

---

## 12. Aller plus loin : Terraform appelle Ansible 🔗

À créer, si vous voulez l'essayer : `lab/terraform/02-parc-multi-os/ansible.tf`
(il n'est pas fourni dans le dépôt).

```hcl
resource "terraform_data" "ansible" {
  triggers_replace = [
    join(",", [for k, v in proxmox_virtual_environment_vm.parc : v.id])
  ]

  provisioner "local-exec" {
    working_dir = "${path.module}/../../ansible"
    command     = <<-EOT
      sleep 45
      rm -rf /tmp/ansible-pve-cache
      ansible-playbook site.yml
    EOT
  }
}
```

`terraform apply` crée les VM et les configure, en une commande.

🪤 Le `sleep 45` est un pis-aller. En vrai, on fait attendre Ansible :

```yaml
- name: Attendre que SSH réponde
  ansible.builtin.wait_for_connection:
    timeout: 300
    delay: 10
```

---

## ✅ Checklist de validation

- [ ] `ansible-inventory --graph` liste mes machines, groupées par tag
- [ ] `ansible linux -m ping` renvoie `pong` sur toutes les VM Terraform
- [ ] Mon PC joint les VM directement (route `10.10.0.0/16 via $PVE`)
- [ ] `ansible-playbook site.yml` se termine sans échec
- [ ] Un **second** passage renvoie `changed=0` partout
- [ ] La page web générée affiche le bon hostname, la bonne IP et les bons groupes
- [ ] PostgreSQL tourne sur la machine taguée `db`, écoute sur le réseau interne
- [ ] Le rôle `common` fonctionne **à la fois** sur Debian/Ubuntu et sur Rocky
- [ ] `ansible-playbook alpine.yml` amorce les LXC Alpine (Python installé par `raw`)
- [ ] Ajouter le tag `web` à `cloud01` (120) a suffi à lui faire appliquer le rôle `web`

---

## 🎁 Bonus

1. **Un troisième rôle** : `monitoring`, qui déploie Prometheus sur la machine taguée
   `services` et génère automatiquement sa configuration de scrape depuis l'inventaire
   (`{% for h in groups['linux'] %}`).
2. **`ansible-vault`** : chiffrez `group_vars/proxmox_db.yml` en entier
   (`ansible-vault encrypt`) et jouez avec `--vault-password-file`.
3. **`ansible-lint`** : `pipx install ansible-lint && ansible-lint`. Corrigez tout ;
   ça se met dans une CI.
4. **Molecule** : testez le rôle `common` dans un conteneur, hors de votre lab.
5. **Inventaire multi-nœuds** : au **jour 4**, une fois le cluster monté, un seul
   fichier `proxmox.yml` couvrira les six nœuds. Anticipez : que faudra-t-il changer ?
   (Réponse : rien, sinon l'URL.)
6. **Le rôle `nfs` sur votre poste** : le même rôle, joué sur `localhost` au TP 14.
   Regardez `roles/nfs/tasks/main.yml` et repérez ce que la variable `nfs_manage_disk`
   permet de sauter.

➡️ Suite : [TP 14 — Un serveur NFS sur votre poste Ubuntu](14-nfs-poste-ubuntu.md)
