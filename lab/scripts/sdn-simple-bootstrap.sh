#!/usr/bin/env bash
# Crée les zones/VNets/subnets « internal » et « dmz » du TP 08.
# À exécuter SUR LE NŒUD PROXMOX, en root.
#
#   ./sdn-simple-bootstrap.sh              # nœud isolé (jours 1-3)
#   ./sdn-simple-bootstrap.sh --node pve3  # pour restreindre la zone à un nœud
set -euo pipefail

NODE=""; DRYRUN=0
GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info(){ printf "${GREEN}==>${NC} %s\n" "$*"; }
warn(){ printf "${YEL}/!\\${NC} %s\n" "$*"; }
die(){  printf "${RED}ERREUR:${NC} %s\n" "$*" >&2; exit 1; }
run(){  if [ "$DRYRUN" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)  NODE="$2";  shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) echo "Usage: $0 [--node <nom>] [--dry-run]"; exit 0 ;;
    *) die "option inconnue : $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die "à exécuter en root"

# ─── Prérequis ───────────────────────────────────────────────────────────────
info "vérification des prérequis"
dpkg -l dnsmasq >/dev/null 2>&1 || die "dnsmasq n'est pas installé (apt install dnsmasq)"
if systemctl is-active --quiet dnsmasq; then
  die "le service dnsmasq système est ACTIF — il bloquera le DHCP du SDN.
     Corrigez avec : systemctl disable --now dnsmasq"
fi
[[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]] || {
  warn "activation de net.ipv4.ip_forward"
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-lab-forward.conf
  sysctl --system >/dev/null
}

# ─── Définition ──────────────────────────────────────────────────────────────
#  zone   vnet   3e octet   alias
ZONES=(
  "zint vint 10 Reseau-interne"
  "zdmz vdmz 20 DMZ"
)

for entry in "${ZONES[@]}"; do
  read -r ZONE VNET OCT ALIAS <<<"$entry"
  NET="10.10.${OCT}.0/24"
  GW="10.10.${OCT}.1"
  DHCP_START="10.10.${OCT}.100"
  DHCP_END="10.10.${OCT}.200"

  info "zone $ZONE"
  if pvesh get "/cluster/sdn/zones/$ZONE" &>/dev/null; then
    warn "la zone $ZONE existe déjà, ignorée"
  else
    # Sans --nodes, la zone s'applique à tous les nœuds : sur un nœud isolé, c'est le bon choix.
    run pvesh create /cluster/sdn/zones \
      --zone "$ZONE" --type simple ${NODE:+--nodes "$NODE"} --ipam pve --dhcp dnsmasq
  fi

  info "vnet $VNET"
  if pvesh get "/cluster/sdn/vnets/$VNET" &>/dev/null; then
    warn "le vnet $VNET existe déjà, ignoré"
  else
    run pvesh create /cluster/sdn/vnets \
      --vnet "$VNET" --zone "$ZONE" --alias "$ALIAS"
  fi

  info "subnet $NET (gw $GW, snat, dhcp ${DHCP_START}-${DHCP_END})"
  if pvesh get "/cluster/sdn/vnets/$VNET/subnets" 2>/dev/null | grep -q "${NET%/*}"; then
    warn "le subnet existe déjà, ignoré"
  else
    run pvesh create "/cluster/sdn/vnets/$VNET/subnets" \
      --subnet "$NET" --type subnet --gateway "$GW" --snat 1 \
      --dhcp-range "start-address=${DHCP_START},end-address=${DHCP_END}"
  fi
done

info "application de la configuration SDN"
run pvesh set /cluster/sdn
sleep 3

# ─── Vérification ────────────────────────────────────────────────────────────
if [ "$DRYRUN" = 0 ]; then
  printf "\n${GREEN}== Vérification ==${NC}\n"
  ip -br a | grep -E 'vint|vdmz' || warn "aucune interface vint/vdmz — l'apply a-t-il réussi ?"
  echo
  for z in zint zdmz; do
    printf "  dnsmasq@%s : %s\n" "$z" "$(systemctl is-active "dnsmasq@$z" 2>/dev/null || echo inactive)"
  done
  echo
  if diff -q /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg >/dev/null 2>&1; then
    printf "  ${GREEN}✔ configuration synchronisée (pas de pending)${NC}\n"
  else
    warn "il reste des modifications en attente — relancez : pvesh set /cluster/sdn"
  fi
fi

printf "\n${GREEN}✔ Terminé.${NC} Réseaux : 10.10.10.0/24 (vint) et 10.10.20.0/24 (vdmz)\n\n"
