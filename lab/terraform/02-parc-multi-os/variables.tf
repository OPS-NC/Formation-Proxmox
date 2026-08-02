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

variable "templates" {
  description = "VMID des templates fabriqués au TP 10, par système"
  type        = map(number)
  default     = {}
}

variable "lxc_template_alpine" {
  description = "Template LXC Alpine, ex. local:vztmpl/alpine-3.22-default_20250617_amd64.tar.xz"
  type        = string
}

variable "machines" {
  description = "Le parc à déployer. Ajouter une VM = ajouter une ligne."
  type = map(object({
    template = string
    vnet     = string
    cores    = number
    memory   = number
    tags     = list(string)
  }))
  default = {
    "web01" = { template = "ubuntu", vnet = "vdmz", cores = 2, memory = 2048, tags = ["web", "dmz", "ubuntu"] }
    "app01" = { template = "debian", vnet = "vint", cores = 2, memory = 2048, tags = ["app", "interne", "debian"] }
    "db01"  = { template = "rocky", vnet = "vint", cores = 2, memory = 3072, tags = ["db", "interne", "rocky"] }
  }
}
