variable "pve_endpoint" { type = string }
variable "pve_api_token" {
  type      = string
  sensitive = true
}
variable "pve_host" { type = string }
variable "pve_node" { type = string }

variable "eleve" {
  type        = number
  description = "Élève qui héberge le serveur NFS de la salle"
}

variable "ssh_public_key" { type = string }

variable "template_debian" {
  type    = number
  default = null
}

variable "nfs_ip" {
  type    = string
  default = "192.168.50.40/24"
}

variable "nfs_gateway" {
  type    = string
  default = "192.168.50.254"
}

variable "data_disk_size" {
  description = "Taille du disque de données, en Go"
  type        = number
  default     = 60
}
