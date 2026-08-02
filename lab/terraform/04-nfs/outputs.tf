output "vm_id" { value = proxmox_virtual_environment_vm.nfs.vm_id }
output "ip" { value = split("/", var.nfs_ip)[0] }

output "etape_suivante" {
  value = <<-EOT

    ① Configurer le serveur avec Ansible (le tag « nfs » suffit) :
         cd ../../ansible
         rm -rf /tmp/ansible-pve-cache
         ansible-inventory --graph | grep -A2 proxmox_nfs
         ansible-playbook site.yml --limit proxmox_nfs

    ② Vérifier depuis un nœud :
         showmount -e ${split("/", var.nfs_ip)[0]}

    ③ Déclarer le stockage (une seule fois pour tout le cluster) :
         pvesm add nfs nfs-lab --server ${split("/", var.nfs_ip)[0]} \
           --export /srv/nfs/images \
           --content images,rootdir,iso,backup,snippets \
           --options vers=4.2

  EOT
}
