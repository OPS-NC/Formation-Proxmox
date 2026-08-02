variable "pve_endpoint" {
  description = "URL de l'API Proxmox, ex. https://192.168.50.13:8006/"
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
  description = "Nom du nœud, ex. pve3"
  type        = string
}

variable "eleve" {
  description = "Numéro d'élève (1-6) — détermine VMID et subnets"
  type        = number

  validation {
    condition     = var.eleve >= 1 && var.eleve <= 6
    error_message = "Le numéro d'élève doit être compris entre 1 et 6."
  }
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée par cloud-init"
  type        = string
}

variable "template_debian" {
  description = "VMID du template Debian 13 (TP 10)"
  type        = number
  default     = null
}

variable "vnet" {
  description = "VNet SDN de rattachement"
  type        = string
  default     = "vint"
}
