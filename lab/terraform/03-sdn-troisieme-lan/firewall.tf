# Les règles de firewall d'un VNet vivent dans /etc/pve/sdn/firewall/<vnet>.fw.
# On les génère depuis un template, puis on les dépose par SSH.
#
# 🧠 Ce n'est pas de la triche : Terraform ne couvre pas encore tous les objets
#    de l'API Proxmox. Combiner ressources natives et local-exec ciblés est une
#    pratique acceptable — tant que c'est idempotent et déclenché par un trigger
#    explicite, comme ici (content_md5).

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
  depends_on = [terraform_data.sdn_apply]

  triggers_replace = [local_file.fw_vsrv.content_md5]

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no root@${var.pve_host} 'mkdir -p /etc/pve/sdn/firewall'
      scp -o StrictHostKeyChecking=no ${local_file.fw_vsrv.filename} \
          root@${var.pve_host}:/etc/pve/sdn/firewall/vsrv.fw
      ssh -o StrictHostKeyChecking=no root@${var.pve_host} \
          'pvesh set /cluster/sdn && (systemctl reload proxmox-firewall || systemctl restart proxmox-firewall)'
    EOT
  }
}
