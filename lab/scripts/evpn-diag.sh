#!/usr/bin/env bash
# Diagnostic complet d'une zone SDN EVPN. À exécuter sur chaque nœud.
#
#   ./evpn-diag.sh [--zone zevpn]
set -uo pipefail

ZONE="${ZONE:-zevpn}"
[[ "${1:-}" == "--zone" ]] && ZONE="$2"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
OK=0; KO=0
titre(){ printf "\n${BLU}══ %s ══${NC}\n" "$1"; }
ok(){    printf "  ${GREEN}[OK]${NC} %s\n" "$1"; OK=$((OK+1)); }
ko(){    printf "  ${RED}[KO]${NC} %s\n" "$1"; KO=$((KO+1)); }
warn(){  printf "  ${YEL}[!!]${NC} %s\n" "$1"; }

printf "${BLU}Diagnostic EVPN — nœud %s — zone %s${NC}\n" "$(hostname)" "$ZONE"

# ─── 1. Paquets ──────────────────────────────────────────────────────────────
titre "1. Prérequis logiciels"
dpkg -l frr             2>/dev/null | grep -q '^ii' && ok "frr installé"             || ko "frr ABSENT — apt install frr"
dpkg -l frr-pythontools 2>/dev/null | grep -q '^ii' && ok "frr-pythontools installé" || ko "frr-pythontools ABSENT — c'est LE grand oubli"
systemctl is-active --quiet frr && ok "service frr actif" || ko "service frr inactif"
[[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]] && ok "ip_forward activé" || ko "ip_forward désactivé"

# ─── 2. Configuration SDN ────────────────────────────────────────────────────
titre "2. Configuration SDN"
if [ -f /etc/pve/sdn/zones.cfg ] && grep -q "evpn: $ZONE" /etc/pve/sdn/zones.cfg; then
  ok "zone $ZONE déclarée"
  sed -n "/evpn: $ZONE/,/^[a-z]*:/p" /etc/pve/sdn/zones.cfg | sed 's/^/       /'

  grep -A15 "evpn: $ZONE" /etc/pve/sdn/zones.cfg | grep -q 'exitnodes ' \
    && ok "exit nodes définis" || warn "aucun exit node : pas d'accès Internet"

  if grep -A15 "evpn: $ZONE" /etc/pve/sdn/zones.cfg | grep -q 'exitnodes-primary'; then
    ok "exitnodes-primary défini"
  else
    ko "exitnodes-primary ABSENT — Internet sera intermittent si SNAT est actif"
  fi

  MTU=$(grep -A15 "evpn: $ZONE" /etc/pve/sdn/zones.cfg | grep -oP 'mtu \K[0-9]+' | head -1)
  if [ "${MTU:-1500}" -le 1450 ]; then ok "MTU = ${MTU:-non défini}"
  else ko "MTU = ${MTU:-1500} — trop élevé pour VXLAN, mettez 1450"; fi
else
  ko "zone $ZONE introuvable dans /etc/pve/sdn/zones.cfg"
fi

if diff -q /etc/pve/sdn/zones.cfg /etc/pve/sdn/zones.running.cfg >/dev/null 2>&1; then
  ok "configuration appliquée (pas de pending)"
else
  ko "modifications EN ATTENTE — lancez : pvesh set /cluster/sdn"
fi

# ─── 3. Interfaces ───────────────────────────────────────────────────────────
titre "3. Interfaces réseau"
if ip link show "vrf_${ZONE}" &>/dev/null; then ok "VRF vrf_${ZONE} présent"; else ko "VRF vrf_${ZONE} ABSENT"; fi
NVX=$(ip -br link show type vxlan 2>/dev/null | wc -l)
[ "$NVX" -gt 0 ] && ok "$NVX interface(s) VXLAN" || ko "aucune interface VXLAN"
echo
ip -br a | grep -E '^(v[a-z]{3,8}|vxlan_|vrf_)' | sed 's/^/       /' || true

# ─── 4. BGP ──────────────────────────────────────────────────────────────────
titre "4. Sessions BGP EVPN"
if command -v vtysh >/dev/null 2>&1; then
  SUM=$(vtysh -c "show bgp l2vpn evpn summary" 2>/dev/null || true)
  if [ -n "$SUM" ]; then
    echo "$SUM" | sed 's/^/       /' | head -20
    EST=$(echo "$SUM" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ .*[[:space:]][0-9]+$' || true)
    DOWN=$(echo "$SUM" | grep -cE 'Active|Connect|Idle' || true)
    echo
    [ "$EST" -gt 0 ]  && ok "$EST voisin(s) établi(s)" || ko "aucun voisin établi"
    [ "$DOWN" -gt 0 ] && ko "$DOWN voisin(s) NON établi(s) — vérifiez le port 179 et les IP des peers"
  else
    ko "vtysh ne répond pas — le démon bgpd tourne-t-il ?"
  fi
else
  ko "vtysh introuvable"
fi

# ─── 5. Routes ───────────────────────────────────────────────────────────────
titre "5. Routes du VRF"
if ip link show "vrf_${ZONE}" &>/dev/null; then
  ip route show vrf "vrf_${ZONE}" | sed 's/^/       /'
  ip route show vrf "vrf_${ZONE}" | grep -q '^default' \
    && ok "route par défaut présente (exit node joignable)" \
    || ko "AUCUNE route par défaut — les VM n'auront pas Internet"
fi

# ─── 6. SNAT (exit node) ─────────────────────────────────────────────────────
# 🧠 pve-network (EvpnPlugin.pm) ne pose les règles SNAT QUE sur les exit nodes.
#    Sur un nœud ordinaire, l'absence de règle n'est pas une panne : le NAT se
#    fait sur l'exit node, après décapsulation du VXLAN. On lit donc d'abord la
#    configuration pour savoir ce qu'on DEVRAIT trouver.
titre "6. SNAT (posé uniquement sur les exit nodes)"
ME="$(hostname)"
EXITNODES=$(grep -A15 "evpn: $ZONE" /etc/pve/sdn/zones.cfg 2>/dev/null \
            | grep -oP '^\s*exitnodes \K.*' | head -1)
PRIMARY=$(grep -A15 "evpn: $ZONE" /etc/pve/sdn/zones.cfg 2>/dev/null \
          | grep -oP '^\s*exitnodes-primary \K.*' | head -1)
IS_EXIT=0
case ",${EXITNODES}," in *",${ME},"*) IS_EXIT=1 ;; esac

printf "       exit nodes : %s   (primaire : %s)\n" "${EXITNODES:-aucun}" "${PRIMARY:-non défini}"

NAT=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -ciE 'masquerade|snat' || true)
if [ "$IS_EXIT" = 1 ]; then
  if [ "$NAT" -gt 0 ]; then
    ok "$ME est exit node et porte $NAT règle(s) SNAT"
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -iE 'masquerade|snat' | head -5 | sed 's/^/       /'
  else
    ko "$ME est déclaré exit node mais ne porte AUCUNE règle SNAT — apply oublié ?"
  fi
else
  if [ "$NAT" -gt 0 ]; then
    warn "$ME n'est PAS exit node mais porte des règles SNAT (reste d'un TP précédent ?)"
  else
    ok "aucune règle SNAT, et c'est NORMAL : $ME n'est pas exit node"
  fi
  printf "       Le NAT se fait sur %s. Vos VM sortent quand meme :\n" "${PRIMARY:-un exit node}"
  printf "       elles suivent la route par défaut apprise en BGP (section 5).\n"
fi

# ─── 7. Ports entre nœuds ────────────────────────────────────────────────────
titre "7. Trafic VXLAN observé (5 s)"
if command -v tcpdump >/dev/null 2>&1; then
  CNT=$(timeout 5 tcpdump -ni any udp port 4789 2>/dev/null | wc -l || true)
  [ "$CNT" -gt 0 ] && ok "$CNT paquet(s) VXLAN capturé(s)" \
                   || warn "aucun paquet VXLAN en 5 s (normal si aucune VM ne communique)"
else
  warn "tcpdump absent"
fi

# ─── 8. VNI ──────────────────────────────────────────────────────────────────
titre "8. VNI EVPN"
vtysh -c "show evpn vni" 2>/dev/null | sed 's/^/       /' | head -15 || warn "indisponible"

# ─── Résumé ──────────────────────────────────────────────────────────────────
printf "\n${BLU}══ Résumé ══${NC}\n"
if [ "$KO" -eq 0 ]; then
  printf "  ${GREEN}Tout est vert (%d contrôles).${NC}\n\n" "$OK"
else
  printf "  ${RED}%d problème(s)${NC} sur %d contrôles.\n" "$KO" "$((OK+KO))"
  cat <<'EOF'

  Ordre de résolution conseillé :
    1. frr + frr-pythontools sur TOUS les nœuds
    2. ports UDP 4789 et TCP 179 ouverts dans cluster.fw
    3. pvesh set /cluster/sdn   (l'apply oublié)
    4. exitnodes-primary défini si SNAT est actif
    5. MTU 1450 sur la zone ET mtu=1 sur les cartes virtio des VM

EOF
  exit 1
fi
