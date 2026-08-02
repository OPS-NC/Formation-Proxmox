output "vmids" {
  description = "VMID attribués, par machine"
  value       = { for k, v in proxmox_virtual_environment_vm.parc : k => v.vm_id }
}

output "tags" {
  description = "Tags posés — ils pilotent l'inventaire Ansible du TP 13"
  value       = { for k, v in proxmox_virtual_environment_vm.parc : k => v.tags }
}

output "ips" {
  description = "IP remontées par l'agent QEMU"
  value = {
    for k, v in proxmox_virtual_environment_vm.parc :
    k => try(flatten(v.ipv4_addresses)[1], "en attente de l'agent")
  }
}

output "container_id" {
  value = proxmox_virtual_environment_container.cache.vm_id
}

output "etape_suivante" {
  value = <<-EOT

    Les machines sont créées. Configurez-les avec Ansible :

      cd ../../ansible
      rm -rf /tmp/ansible-pve-cache
      ansible-inventory --graph
      ansible-playbook site.yml

  EOT
}
