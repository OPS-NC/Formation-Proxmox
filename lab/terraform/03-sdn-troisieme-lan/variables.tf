variable "pve_endpoint" { type = string }
variable "pve_api_token" {
  type      = string
  sensitive = true
}
variable "pve_host" { type = string }
variable "pve_node" { type = string }

variable "eleve" {
  type = number
  validation {
    condition     = var.eleve >= 1 && var.eleve <= 6
    error_message = "Le numéro d'élève doit être compris entre 1 et 6."
  }
}

variable "ssh_public_key" { type = string }

variable "template_debian" {
  type    = number
  default = null
}

variable "lxc_template_alpine" { type = string }
