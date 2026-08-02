provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = true # certificat auto-signé du lab

  # Nécessaire pour les opérations que l'API ne couvre pas
  # (dépôt de snippets cloud-init par SCP, notamment).
  ssh {
    agent    = true
    username = "root"
  }
}
