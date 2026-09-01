# Fichiers cloud-init

## Déposer les snippets sur le nœud

Le stockage doit accepter le content `snippets` (TP 02 §4).

```bash
scp *.yaml root@172.30.30.153:/var/lib/vz/snippets/
```

## Les utiliser

```bash
# user-data seul
qm set <vmid> --cicustom "user=local:snippets/user-data-web.yaml"

# user-data + vendor-data + network-config
qm set <vmid> --cicustom "user=local:snippets/user-data-web.yaml,vendor=local:snippets/vendor-data-common.yaml,network=local:snippets/network-config-static.yaml"

qm stop <vmid> && qm start <vmid>     # ⚠ arrêt/démarrage, pas un simple reboot
```

## Valider avant de déployer

```bash
cloud-init schema --config-file user-data-web.yaml --annotate
```

## Déboguer

```bash
# Côté hôte : ce que Proxmox a réellement généré
qm cloudinit dump <vmid> user
qm cloudinit dump <vmid> network

# Dans la VM
cloud-init status --long
sudo cat /var/log/cloud-init-output.log
sudo cloud-init clean --logs --reboot     # rejouer depuis zéro
```

## Les trois pièges

1. **`#cloud-config` en première ligne**, sans espace avant. Sinon le fichier est
   ignoré en silence.
2. **cloud-init ne s'exécute qu'une fois par instance-id.** Modifier la configuration
   et redémarrer ne suffit pas : il faut un `cloud-init clean`, ou un arrêt/démarrage
   complet côté Proxmox.
3. **`user_data_file_id` remplace** le compte généré par Proxmox. Si vous voulez
   conserver votre clé SSH, remettez-la dans le YAML (`ssh_authorized_keys`).
