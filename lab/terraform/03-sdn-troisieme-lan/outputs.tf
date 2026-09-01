output "zone" { value = proxmox_sdn_zone_simple.srv.id }
output "vnet" { value = proxmox_sdn_vnet.srv.id }
output "subnet" { value = proxmox_sdn_subnet.srv.cidr }
output "gateway" { value = local.gw_srv }

output "guests" {
  value = {
    mon01 = proxmox_virtual_environment_vm.mon.vm_id
    log01 = proxmox_virtual_environment_container.log.vm_id
  }
}

output "verification" {
  value = <<-EOT

    Vérifiez sur le nœud :
      ssh root@${var.pve_host} 'ip -br a | grep vsrv'
      ssh root@${var.pve_host} 'cat /etc/pve/sdn/firewall/vsrv.fw'
      ssh root@${var.pve_host} 'systemctl status dnsmasq@zsrv --no-pager | head -3'

    Tests attendus depuis mon01 :
      nc -zvw2 <ip-db> 9100   → ✅  (exige la règle vsrv→vint dans vint.fw)
      nc -zvw2 <ip-db> 5432   → ❌
      ping 1.1.1.1            → ❌ (ICMP non autorisé vers Internet)
      curl -sI https://debian.org → ✅

  EOT
}
