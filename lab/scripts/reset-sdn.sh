#!/usr/bin/env bash
# Supprime TOUTE la configuration SDN (subnets → vnets → zones → controllers).
# Utile pour repartir de zéro sur un nœud isolé (jours 2-3).
#
#   ./reset-sdn.sh            # demande confirmation
#   ./reset-sdn.sh --yes      # sans confirmation
set -euo pipefail

YES=0
[[ "${1:-}" == "--yes" ]] && YES=1
GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info(){ printf "${GREEN}==>${NC} %s\n" "$*"; }
warn(){ printf "${YEL}/!\\${NC} %s\n" "$*"; }

[[ $EUID -eq 0 ]] || { echo "à exécuter en root"; exit 1; }

printf "${RED}"
cat <<'EOF'
 ┌────────────────────────────────────────────────────────────┐
 │  ATTENTION                                                 │
 │  Ce script supprime TOUTE la configuration SDN du cluster : │
 │  subnets, VNets, zones, contrôleurs et règles firewall SDN. │
 │  Les guests branchés sur ces VNets perdront leur réseau.    │
 └────────────────────────────────────────────────────────────┘
EOF
printf "${NC}\n"

echo "Configuration actuelle :"
pvesh get /cluster/sdn/zones --output-format json 2>/dev/null \
  | jq -r '.[] | "  zone \(.zone) (\(.type))"' 2>/dev/null || echo "  (aucune)"
pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null \
  | jq -r '.[] | "  vnet \(.vnet) → \(.zone)"' 2>/dev/null || true
echo

# Guests encore branchés ?
BUSY=$(grep -lE 'bridge=(v[a-z0-9]{1,7})' /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf 2>/dev/null \
       | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ' || true)
[[ -n "${BUSY// }" ]] && warn "guests potentiellement concernés : $BUSY"

if [ "$YES" = 0 ]; then
  read -r -p "Confirmer la suppression ? (tapez OUI) : " ans
  [[ "$ans" == "OUI" ]] || { echo "Annulé."; exit 0; }
fi

# Sauvegarde avant destruction
BAK="/root/sdn-backup-$(date +%F-%H%M%S).tgz"
tar czf "$BAK" /etc/pve/sdn 2>/dev/null && info "sauvegarde : $BAK"

# 1. Règles firewall des VNets
if [ -d /etc/pve/sdn/firewall ]; then
  info "suppression des règles firewall SDN"
  rm -f /etc/pve/sdn/firewall/*.fw
fi

# 2. Subnets  →  3. VNets   (ordre imposé)
for vnet in $(pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null | jq -r '.[].vnet' 2>/dev/null); do
  for sub in $(pvesh get "/cluster/sdn/vnets/$vnet/subnets" --output-format json 2>/dev/null | jq -r '.[].subnet' 2>/dev/null); do
    info "suppression du subnet $sub (vnet $vnet)"
    pvesh delete "/cluster/sdn/vnets/$vnet/subnets/$sub" 2>/dev/null || warn "échec sur $sub"
  done
  info "suppression du vnet $vnet"
  pvesh delete "/cluster/sdn/vnets/$vnet" 2>/dev/null || warn "échec sur $vnet"
done

# 4. Zones
for zone in $(pvesh get /cluster/sdn/zones --output-format json 2>/dev/null | jq -r '.[].zone' 2>/dev/null); do
  info "suppression de la zone $zone"
  pvesh delete "/cluster/sdn/zones/$zone" 2>/dev/null || warn "échec sur $zone"
done

# 5. Contrôleurs
for c in $(pvesh get /cluster/sdn/controllers --output-format json 2>/dev/null | jq -r '.[].controller' 2>/dev/null); do
  info "suppression du contrôleur $c"
  pvesh delete "/cluster/sdn/controllers/$c" 2>/dev/null || warn "échec sur $c"
done

info "application"
pvesh set /cluster/sdn || warn "l'apply a signalé une erreur"
sleep 2

printf "\n${GREEN}== État final ==${NC}\n"
pvesh get /cluster/sdn/zones 2>/dev/null || true
ip -br a | grep -E '^(v[a-z]{3}|vrf_)' && warn "des interfaces SDN subsistent (redémarrage nécessaire ?)" \
                                       || info "plus aucune interface SDN"
printf "\n${GREEN}✔ SDN remis à zéro.${NC} Sauvegarde : %s\n\n" "$BAK"
