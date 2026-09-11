# Les règles de firewall d'un VNet vivent dans /etc/pve/sdn/firewall/<vnet>.fw.
# Le provider ne couvre pas cet objet : on génère le fichier depuis un template,
# puis on le dépose par SSH.
#
# 🧠 Ce n'est pas de la triche : Terraform ne couvre pas encore tous les objets
#    de l'API Proxmox. Combiner ressources natives et local-exec ciblés est une
#    pratique acceptable — tant que c'est idempotent et déclenché par un trigger
#    explicite, comme ici (content_md5).
#
#    Comparez avec sdn.tf : là où une ressource native existe
#    (proxmox_sdn_applier), on l'utilise. Le local-exec est
#    le dernier recours, pas le réflexe.
#
# 🪤 Un local-exec ne s'exécute que si TOUTES ses dépendances ont réussi. Si une
#    dépendance échoue, Terraform saute cette ressource SANS message : ni
#    « Provisioning… », ni scp. On ne dépend donc que du strict nécessaire : le VNet
#    appliqué (IPSets +sdn/vsrv-*) et le dépôt de cluster.fw, qui porte l'alias
#    lan_salle référencé ici.

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
  depends_on = [
    proxmox_sdn_applier.apply,      # +sdn/vsrv-all et +sdn/vsrv-gateway existent
    terraform_data.push_cluster_fw, # l'alias lan_salle référencé ici vit dans cluster.fw
  ]

  # Lisible par le provisioner de destruction (qui n'a pas accès à var.*).
  input = { host = var.pve_host }

  triggers_replace = [local_file.fw_vsrv.content_md5]

  # BatchMode=yes : sans clé acceptée par root, ssh échoue net au lieu d'attendre
  # un mot de passe que Terraform ne saisira jamais.
  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@${var.pve_host}"
      echo ">> dépôt de vsrv.fw sur ${var.pve_host}:/etc/pve/sdn/firewall/"
      $SSH 'mkdir -p /etc/pve/sdn/firewall'
      scp -o BatchMode=yes -o StrictHostKeyChecking=no ${local_file.fw_vsrv.filename} \
          root@${var.pve_host}:/etc/pve/sdn/firewall/vsrv.fw
      # L'unité n'a pas de ExecReload : « reload » échoue toujours, on redémarre.
      $SSH 'systemctl restart proxmox-firewall'
      echo ">> vsrv.fw déposé, proxmox-firewall redémarré"
    EOT
  }

  # Au destroy : retirer le fichier AVANT que le VNet disparaisse, sinon
  # proxmox-firewall boucle sur « could not find ipset vsrv-all ».
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@${self.input.host} 'rm -f /etc/pve/sdn/firewall/vsrv.fw && systemctl restart proxmox-firewall'"
  }
}
