output "vm_id" {
  description = "VMID attribué"
  value       = proxmox_virtual_environment_vm.web.vm_id
}

output "vm_name" {
  value = proxmox_virtual_environment_vm.web.name
}

output "ipv4_addresses" {
  description = "Adresses remontées par l'agent QEMU (vide si l'agent ne répond pas encore)"
  value       = proxmox_virtual_environment_vm.web.ipv4_addresses
}

output "ssh_hint" {
  description = "Comment se connecter, via le nœud en rebond"
  value       = "ssh -J root@${var.pve_host} eleve@<ip-obtenue>"
}
