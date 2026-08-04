#!/usr/bin/env bash
# Vérifie que le poste de l'élève dispose des outils nécessaires.
# Usage : bash lab/scripts/00-check-env.sh
set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
ERRORS=0; WARNS=0

titre()  { printf "\n${BLU}== %s ==${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC}   %s\n" "$1"; }
ko()     { printf "  ${RED}[KO]${NC}   %s\n" "$1"; ERRORS=$((ERRORS+1)); }
warn()   { printf "  ${YEL}[!!]${NC}   %s\n" "$1"; WARNS=$((WARNS+1)); }

check_cmd() { # <binaire> <paquet apt> [optionnel]
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 — $("$1" --version 2>/dev/null | head -1 | cut -c1-60)"
  elif [ "${3:-}" = "optionnel" ]; then
    warn "$1 absent (optionnel) — sudo apt install -y $2"
  else
    ko "$1 absent — sudo apt install -y $2"
  fi
}

printf "${BLU}Vérification du poste de travail — formation Proxmox VE 9${NC}\n"

titre "Outils de base"
check_cmd git      git
check_cmd ssh      openssh-client
check_cmd curl     curl
check_cmd jq       jq
check_cmd dig      dnsutils
check_cmd nc       netcat-openbsd

titre "Infrastructure as Code"
if command -v terraform >/dev/null 2>&1; then
  ok "terraform — $(terraform version | head -1)"
elif command -v tofu >/dev/null 2>&1; then
  ok "opentofu — $(tofu version | head -1)"
else
  ko "ni terraform ni tofu — voir TP 00 §6"
fi
check_cmd ansible ansible
if command -v ansible-galaxy >/dev/null 2>&1; then
  if ansible-galaxy collection list 2>/dev/null | grep -q community.general; then
    ok "collection community.general présente"
  else
    ko "collection manquante — ansible-galaxy collection install community.general ansible.posix"
  fi
fi
if python3 -c 'import proxmoxer' 2>/dev/null; then
  ok "module python proxmoxer présent"
else
  ko "proxmoxer absent — sudo apt install -y python3-proxmoxer"
fi

titre "Accès distant (TP 04 : Windows)"
if command -v xfreerdp3 >/dev/null 2>&1 || command -v xfreerdp >/dev/null 2>&1 \
   || command -v remmina >/dev/null 2>&1; then
  ok "client RDP présent"
else
  warn "aucun client RDP — sudo apt install -y freerdp3-x11  (ou remmina)"
fi
check_cmd remote-viewer virt-viewer optionnel

titre "Serveur NFS (TP 14)"
if dpkg -l nfs-kernel-server 2>/dev/null | grep -q '^ii'; then
  ok "nfs-kernel-server installé"
  if systemctl is-active --quiet nfs-server; then ok "nfs-server actif"; else warn "nfs-server inactif"; fi
  if [ -n "$(ls /etc/exports.d/*.exports 2>/dev/null)" ] || grep -q '^/' /etc/exports 2>/dev/null; then
    ok "au moins un export déclaré :"; sudo -n exportfs -v 2>/dev/null | sed 's/^/         /' | head -6
  else
    warn "aucun export déclaré (normal avant le TP 14)"
  fi
else
  warn "nfs-kernel-server absent — sudo apt install -y nfs-kernel-server  (TP 14)"
fi

titre "Clé SSH"
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
  ok "clé ed25519 : $(cut -d' ' -f3 < "$HOME/.ssh/id_ed25519.pub")"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
  warn "clé RSA trouvée — préférez ed25519 : ssh-keygen -t ed25519"
else
  ko "aucune clé SSH — ssh-keygen -t ed25519 -C \"eleve@formation\" -N ''"
fi

titre "Secrets du lab"
if [ -f "$HOME/.config/pve/token.env" ]; then
  perms=$(stat -c '%a' "$HOME/.config/pve/token.env" 2>/dev/null || stat -f '%A' "$HOME/.config/pve/token.env")
  [ "$perms" = "600" ] && ok "token.env présent (600)" \
                       || warn "token.env en $perms — chmod 600 ~/.config/pve/token.env"
else
  warn "~/.config/pve/token.env absent — il sera créé au TP 06"
fi

titre "Connectivité de la salle"
for h in 192.168.50.254 192.168.50.11; do
  if ping -c1 -W1 "$h" >/dev/null 2>&1; then ok "ping $h"; else warn "pas de réponse de $h (normal si le lab n'est pas encore monté)"; fi
done
if curl -sk --max-time 3 https://192.168.50.11:8006 >/dev/null 2>&1; then
  ok "interface web de pve1 joignable"
else
  warn "pve1:8006 injoignable (normal avant le TP 01)"
fi

printf "\n${BLU}== Résultat ==${NC}\n"
if [ "$ERRORS" -eq 0 ]; then
  printf "  ${GREEN}Poste prêt${NC} — %d avertissement(s)\n\n" "$WARNS"
else
  printf "  ${RED}%d erreur(s)${NC} et %d avertissement(s) — corrigez avant de commencer\n\n" "$ERRORS" "$WARNS"
  exit 1
fi
