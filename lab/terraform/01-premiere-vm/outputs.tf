output "vm_id" {
  description = "VMID attribué"
  value       = proxmox_virtual_environment_vm.web.vm_id
}

output "vm_name" {
  value = proxmox_virtual_environment_vm.web.name
}

output "ssh_hint" {
  description = "Comment se connecter (route vers 10.10.0.0/16 via le nœud, cf. TP 07)"
  value       = "ssh eleve@${try([for ip in flatten(proxmox_virtual_environment_vm.web.ipv4_addresses) : ip if ip != "127.0.0.1"][0], "<ip-obtenue>")}"
}

output "ssh_hint_dns" {
  description = "Comment se connecter (route vers 10.10.0.0/16 via le nœud, cf. TP 07)"
  value       = "ssh eleve@${try([for ip in flatten(proxmox_virtual_environment_vm.dns01.ipv4_addresses) : ip if ip != "127.0.0.1"][0], "<ip-obtenue>")}"
}

