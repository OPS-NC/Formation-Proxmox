# TP 13 — Ansible : inventaire dynamique Proxmox et rôles par tags 🎼

⏱️ **1 h 15** · Jour 3

Objectif : Terraform crée les machines, **Ansible les configure**. Et il ne le fait pas
au hasard : il interroge l'API Proxmox, lit les **tags** posés au TP 11, et applique le
rôle correspondant. Zéro inventaire à maintenir à la main.

📖 Plugin d'inventaire : <https://docs.ansible.com/ansible/latest/collections/community/general/proxmox_inventory.html>

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

🧠 **La frontière** : Terraform s'arrête au moment où la machine démarre. Tout ce qui se
passe *à l'intérieur* du système d'exploitation, c'est Ansible. On peut tout faire en
cloud-init, mais cloud-init ne s'exécute qu'**une fois** — il ne sait pas remettre en
conformité une machine qui a dérivé six mois plus tard. Ansible, si.

---

## 2. Le fil rouge : le tag 🏷️

```
   TP 11               Proxmox                TP 13                TP 13
   ─────               ───────                ─────                ─────
   tags = ["web"] ──► tag "web" sur ──► groupe Ansible ──► rôle « web »
                       la VM 320          proxmox_web            appliqué
                                             │
   tags = ["db"]  ──► tag "db"  ──► groupe proxmox_db ──► rôle « db »
```

**Un tag posé dans Terraform pilote un rôle Ansible.** C'est propre, traçable, et ça
tient dans une revue de code.

---

## 3. Installer Ansible 💻

Sur votre **PC Ubuntu** :

```bash
sudo apt update
sudo apt install -y ansible python3-proxmoxer python3-requests
ansible --version
ansible-galaxy collection install community.general ansible.posix
ansible-galaxy collection list | grep -E 'community.general|ansible.posix'
```

🪤 Le plugin d'inventaire Proxmox a besoin de **`proxmoxer`** côté contrôleur. Sans lui,
l'erreur est laconique : `Invalid data from server`.

---

## 4. La structure du dépôt Ansible 📁

```
lab/ansible/
├── ansible.cfg
├── inventory/
│   └── proxmox.yml           ← ★ l'inventaire dynamique
├── group_vars/
│   ├── all.yml
│   ├── proxmox_web.yml
│   └── proxmox_db.yml
├── roles/
│   ├── common/               ← appliqué partout
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   └── templates/motd.j2
│   ├── web/                  ← machines taguées « web »
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   └── templates/index.html.j2
│   └── db/                   ← machines taguées « db »
│       ├── tasks/main.yml
│       ├── handlers/main.yml
│       └── templates/pg_hba.conf.j2
├── site.yml                  ← le playbook principal
└── ping.yml                  ← test de connectivité
```

```bash
cd ~/ProxmoxFormation/lab/ansible
ls -R | head -40
```

---

## 5. L'inventaire dynamique ⭐

`inventory/proxmox.yml` :

```yaml
---
plugin: community.general.proxmox
url: "https://192.168.50.13:8006"
user: ansible@pve
token_id: inv
token_secret: "{{ lookup('env', 'PVE_ANSIBLE_TOKEN_SECRET') }}"
validate_certs: false

# On ne veut que les machines démarrées
want_facts: true
qemu_extended_statuses: true
exclude_nodes: false

# Les groupes construits automatiquement
keyed_groups:
  # un groupe par tag Proxmox   →  proxmox_web, proxmox_db, proxmox_interne…
  - key: proxmox_tags_parsed
    separator: "_"
    prefix: proxmox
  # un groupe par nœud          →  node_pve3
  - key: proxmox_node
    prefix: node
  # un groupe par pool          →  pool_eleve3
  - key: proxmox_pool
    prefix: pool

groups:
  linux: "proxmox_vmtype == 'qemu' and 'windows' not in (proxmox_tags | default(''))"
  conteneurs: "proxmox_vmtype == 'lxc'"

# L'IP de connexion vient de l'agent QEMU
compose:
  ansible_host: >-
    (proxmox_agent_interfaces | default([])
     | selectattr('name','ne','lo')
     | map(attribute='ip-addresses') | flatten
     | selectattr('ip-address-type','eq','ipv4')
     | map(attribute='ip-address') | list | first) | default(proxmox_name)

cache: true
cache_plugin: jsonfile
cache_timeout: 120
cache_connection: /tmp/ansible-pve-cache
```

🧠 **`keyed_groups` + `proxmox_tags_parsed`** est la ligne qui fait tout le travail.
Chaque tag Proxmox devient un groupe Ansible préfixé `proxmox_`. Ajoutez un tag dans
l'interface → le groupe apparaît à la prochaine exécution. Aucune synchronisation à
gérer.

### Tester l'inventaire

```bash
cd ~/ProxmoxFormation/lab/ansible
source ~/.config/pve/token.env

ansible-inventory -i inventory/proxmox.yml --graph
```

Sortie attendue :

```
@all:
  |--@ungrouped:
  |--@proxmox_all_qemu:
  |  |--web01-e3
  |  |--app01-e3
  |  |--db01-e3
  |--@proxmox_web:
  |  |--web01-e3
  |--@proxmox_db:
  |  |--db01-e3
  |--@proxmox_interne:
  |  |--app01-e3
  |  |--db01-e3
  |--@node_pve3:
  |  |--web01-e3
  |  |--app01-e3
  |  |--db01-e3
```

```bash
# Le détail d'un hôte
ansible-inventory -i inventory/proxmox.yml --host web01-e3 | jq

# Toutes les variables disponibles
ansible-inventory -i inventory/proxmox.yml --list | jq '._meta.hostvars | keys'
```

🪤 **Une machine sans agent QEMU n'aura pas d'`ansible_host`.** Vérifiez que
`qemu-guest-agent` tourne sur vos VM (il est dans les templates du TP 10).

---

## 6. `ansible.cfg` et la connexion 🔌

```ini
[defaults]
inventory            = inventory/proxmox.yml
host_key_checking    = False
remote_user          = eleve
private_key_file     = ~/.ssh/id_ed25519
interpreter_python   = auto_silent
stdout_callback      = yaml
callbacks_enabled    = profile_tasks
retry_files_enabled  = False

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s
```

🪤 **Le problème du lab** : vos VM sont dans les VNets `10.N.x.0/24`, **derrière le
NAT du nœud**. Votre PC Ubuntu ne peut pas les joindre directement. Deux solutions :

### Solution A — rebond SSH par le nœud Proxmox ⭐

Dans `group_vars/all.yml` :

```yaml
---
ansible_ssh_common_args: >-
  -o ProxyCommand="ssh -W %h:%p -q root@{{ pve_host }}"
  -o StrictHostKeyChecking=no
pve_host: 192.168.50.13
```

Le nœud Proxmox devient votre bastion. C'est exactement ce qu'on fait en production.

### Solution B — une route statique sur votre PC

```bash
sudo ip route add 10.3.0.0/16 via 192.168.50.13
```

⚠️ Ne fonctionne que si le firewall du nœud accepte le forward depuis le LAN.
La solution A est plus propre et ne dépend de rien.

### Vérifier

```bash
ansible -i inventory/proxmox.yml linux -m ping
ansible -i inventory/proxmox.yml all -m setup -a 'filter=ansible_distribution*'
```

✅ Vous devez obtenir des `pong` de toutes vos VM Linux.

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
  notify: redemarrer cron

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

- name: redemarrer cron
  ansible.builtin.service:
    name: "{{ 'cron' if ansible_os_family == 'Debian' else 'crond' }}"
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

`group_vars/all.yml` :

```yaml
---
common_timezone: "Pacific/Noumea"
common_admin_user: "eleve"
common_packages:
  - curl
  - vim
  - htop
  - git
  - rsync
```

🧠 **Le rôle est multi-OS.** `ansible.builtin.package` s'adapte à `apt` ou `dnf`,
et les conditions `ansible_os_family` gèrent les différences Debian/RedHat. C'est
tout l'intérêt d'avoir mis du Rocky dans le parc : ça oblige à écrire du code
portable au lieu d'empiler des `apt install`.

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
    validate: 'nginx -t -c /etc/nginx/nginx.conf'
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
  <p>Déployé le {{ ansible_date_time.iso8601 }}</p>
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
db_allowed_network: "10.{{ eleve | default(3) }}.10.0/24"
db_conf_path: >-
  {{ '/etc/postgresql/17/main/postgresql.conf' if ansible_os_family == 'Debian'
     else '/var/lib/pgsql/data/postgresql.conf' }}
db_hba_path: >-
  {{ '/etc/postgresql/17/main/pg_hba.conf' if ansible_os_family == 'Debian'
     else '/var/lib/pgsql/data/pg_hba.conf' }}
```

🪤 **Le mot de passe en clair, c'est non.** Faites-le proprement :

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
- name: Socle commun sur toutes les machines Linux
  hosts: linux
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
ansible-playbook site.yml --tags web
```

### La preuve de l'idempotence 🎯

```bash
ansible-playbook site.yml
```

Relancez immédiatement :

```
PLAY RECAP ****************************************************
web01-e3  : ok=14  changed=0  unreachable=0  failed=0
app01-e3  : ok=11  changed=0  unreachable=0  failed=0
db01-e3   : ok=16  changed=0  unreachable=0  failed=0
```

🧠 **`changed=0` au second passage : c'est LE critère de qualité d'un playbook.**
Si une tâche reste en `changed` à chaque exécution, elle est mal écrite (typiquement
un `command` sans `creates:` ni `changed_when:`). Corrigez-la : un playbook qui ment
sur ce qu'il change devient inutilisable pour détecter les dérives.

### Vérifier le résultat

```bash
# La page web générée
ssh -J root@192.168.50.13 eleve@10.3.20.<ip-web01> 'curl -s localhost | grep h1'

# La base
ssh -J root@192.168.50.13 eleve@10.3.10.<ip-db01> \
  'sudo -u postgres psql -c "\l" | grep applab'

# Le motd
ssh -J root@192.168.50.13 eleve@10.3.10.<ip-app01>
```

---

## 11. Le test qui boucle la boucle 🔁

Ajoutez le tag `web` à une machine qui ne l'avait pas :

```bash
ssh root@192.168.50.13 'qm set 321 --tags "terraform,app,interne,web"'
```

Puis, **sans toucher à l'inventaire** :

```bash
rm -rf /tmp/ansible-pve-cache          # on vide le cache
ansible-inventory -i inventory/proxmox.yml --graph | grep -A3 proxmox_web
ansible-playbook site.yml --limit proxmox_web
```

✅ La machine apparaît dans le groupe et reçoit nginx.

🧠 **Vous venez de faire de la configuration pilotée par étiquette.** C'est le modèle
utilisé par Kubernetes (labels/selectors), par AWS (tags/ASG), par tous les
orchestrateurs modernes. Vous l'avez implémenté sur Proxmox en trente lignes de YAML.

---

## 12. Aller plus loin : Terraform appelle Ansible 🔗

Dans `lab/terraform/02-parc-multi-os/ansible.tf` :

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

`terraform apply` crée les VM **et** les configure. Une seule commande, de zéro à
« en production ».

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
- [ ] `ansible linux -m ping` renvoie `pong` partout
- [ ] Le rebond SSH par le nœud Proxmox fonctionne
- [ ] `ansible-playbook site.yml` se termine sans échec
- [ ] Un **second** passage renvoie `changed=0` partout
- [ ] La page web générée affiche le bon hostname, la bonne IP et les bons groupes
- [ ] PostgreSQL tourne sur la machine taguée `db`, écoute sur le réseau interne
- [ ] Le rôle `common` fonctionne **à la fois** sur Debian/Ubuntu et sur Rocky
- [ ] Ajouter un tag dans Proxmox suffit à faire appliquer le rôle correspondant

---

## 🎁 Bonus

1. **Un troisième rôle** : `monitoring`, qui déploie Prometheus sur la machine taguée
   `services` et génère automatiquement sa configuration de scrape depuis l'inventaire
   (`{% for h in groups['linux'] %}`). C'est là qu'Ansible devient magique.
2. **`ansible-vault`** : chiffrez `group_vars/proxmox_db.yml` en entier
   (`ansible-vault encrypt`) et jouez avec `--vault-password-file`.
3. **`ansible-lint`** : `pipx install ansible-lint && ansible-lint`. Corrigez tout.
   C'est formateur et ça se met dans une CI.
4. **Molecule** : testez le rôle `common` dans un conteneur, hors de votre lab.
5. **Inventaire multi-nœuds** : au **jour 4**, une fois le cluster monté, un seul
   fichier `proxmox.yml` couvrira les six nœuds. Anticipez : que faudra-t-il changer ?
   (Réponse : rien, sinon l'URL. C'est tout l'intérêt d'une API clusterisée.)
6. **Le rôle `nfs` sur votre poste** : c'est exactement ce qu'on fait au TP 14 — le même
   rôle, joué sur `localhost`. Regardez `roles/nfs/tasks/main.yml` et repérez ce que la
   variable `nfs_manage_disk` permet de sauter.

➡️ Suite : [TP 14 — Un serveur NFS sur votre poste Ubuntu](14-nfs-poste-ubuntu.md)
