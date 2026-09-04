variable "pve_endpoint" {
  description = "URL de l'API Proxmox, ex. https://172.30.30.151:8006/ (l'IP de VOTRE nœud)"
  type        = string
}

variable "pve_api_token" {
  description = "Token au format user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "pve_host" {
  description = "IP du nœud (pour les commandes SSH)"
  type        = string
}

variable "pve_node" {
  description = "Nom du nœud : « pve » aux jours 1-3, « pve1 »…« pve6 » une fois en cluster"
  type        = string
  default     = "pve"
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée par cloud-init"
  type        = string
}

variable "template_debian" {
  description = "VMID du template Debian 13 (TP 10)"
  type        = number
  default     = 190
}

variable "vnet" {
  description = "VNet SDN de rattachement"
  type        = string
  default     = "vint"
}
