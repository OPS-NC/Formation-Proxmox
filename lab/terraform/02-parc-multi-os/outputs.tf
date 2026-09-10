
output "ips" {
  description = "IP remontées par l'agent QEMU"
  value = {
    for k, v in proxmox_virtual_environment_vm.parc :
    k => try(flatten(v.ipv4_addresses)[1], "en attente de l'agent")
  }
}

