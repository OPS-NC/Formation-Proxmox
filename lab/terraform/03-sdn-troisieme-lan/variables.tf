variable "pve_endpoint" { type = string }
variable "pve_api_token" {
  type      = string
  sensitive = true
}
variable "pve_host" { type = string }
variable "pve_node" {
  description = "Nom du nœud : « pve » aux jours 1-3, « pve1 »…« pve6 » en cluster"
  type        = string
  default     = "pve"
}

variable "ssh_public_key" { type = string }

variable "template_debian" {
  description = "VMID du template Debian 13 (TP 10)"
  type        = number
  default     = 190
}

variable "lxc_template_alpine" { type = string }
