#!/usr/bin/env bash
# Vérifie la matrice de flux des TP 09 / 12 / 17.
# À exécuter depuis une VM de la zone INTERNE (ou depuis le PC, qui route vers les VNets).
#
#   ./test-firewall.sh --int 10.10.10.101 --dmz 10.10.20.101 --win 10.10.10.102
#   ./test-firewall.sh --int 10.60.10.101 --dmz 10.60.20.101 --mtu 1450   # EVPN
#
# Les gateways sont déduites des adresses (.1 du réseau) ; --gw-int / --gw-dmz pour forcer.
set -uo pipefail

IP_INT=""; IP_DMZ=""; IP_WIN=""; IP_SRV=""; GW_INT=""; GW_DMZ=""
# Compte SSH sur la machine DMZ : root sur un CT (la clé y est posée par pct), eleve sur une VM cloud-init
DMZ_USER="${DMZ_USER:-root}"
# MTU du réseau testé : 1500 en zone Simple (TP 09/12), 1450 en zone EVPN (TP 17).
MTU=1500
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
PASS=0; FAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --int)   IP_INT="$2"; shift 2 ;;
    --gw-int) GW_INT="$2"; shift 2 ;;
    --gw-dmz) GW_DMZ="$2"; shift 2 ;;
    --dmz-user) DMZ_USER="$2"; shift 2 ;;
    --dmz)   IP_DMZ="$2"; shift 2 ;;
    --win)   IP_WIN="$2"; shift 2 ;;
    --srv)   IP_SRV="$2"; shift 2 ;;
    --mtu)   MTU="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --int IP --dmz IP [--win IP] [--srv IP] [--gw-int IP] [--gw-dmz IP] [--dmz-user root|eleve] [--mtu 1500|1450]"
      echo "       --mtu 1450 pour une zone EVPN (TP 17)"
      exit 0 ;;
    *) echo "option inconnue : $1"; exit 1 ;;
  esac
done
[[ -n "$IP_INT" && -n "$IP_DMZ" ]] || { echo "--int et --dmz sont requis"; exit 1; }
IP_SRV="${IP_SRV:-$IP_INT}"
GW_INT="${GW_INT:-${IP_INT%.*}.1}"
GW_DMZ="${GW_DMZ:-${IP_DMZ%.*}.1}"

# attendu = ok | ko
t() { # <description> <attendu> <commande...>
  local desc="$1" want="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=ko; fi
  if [ "$got" = "$want" ]; then
    printf "  ${GREEN}✔${NC} %-52s (%s)\n" "$desc" "$want"; PASS=$((PASS+1))
  else
    printf "  ${RED}✘${NC} %-52s attendu=%s obtenu=%s\n" "$desc" "$want" "$got"; FAIL=$((FAIL+1))
  fi
}

nc_test()   { nc -z -w2 "$1" "$2"; }
ping_test() { ping -c1 -W2 "$1"; }

printf "${BLU}Tests de la matrice de flux — %s${NC}\n" "$(hostname)"
printf "  interne=%s  dmz=%s  windows=%s\n" "$IP_INT" "$IP_DMZ" "${IP_WIN:-n/a}"

printf "\n${BLU}── Depuis la zone INTERNE ──${NC}\n"
t "gateway interne joignable"            ok ping_test "$GW_INT"
t "Internet (ICMP)"                      ok ping_test 1.1.1.1
t "résolution DNS"                       ok getent hosts debian.org
t "interne → DMZ : HTTP 80"              ok nc_test "$IP_DMZ" 80
t "interne → DMZ : SSH 22"               ok nc_test "$IP_DMZ" 22
t "interne → DMZ : MySQL 3306 (refusé)"  ko nc_test "$IP_DMZ" 3306
t "interne → DMZ : 8080 (refusé)"        ko nc_test "$IP_DMZ" 8080
[[ -n "$IP_WIN" ]] && t "interne → Windows : RDP 3389" ok nc_test "$IP_WIN" 3389

printf "\n${BLU}── Depuis la DMZ (via SSH) ──${NC}\n"
if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
       "$DMZ_USER@$IP_DMZ" true 2>/dev/null; then
  R() { ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$DMZ_USER@$IP_DMZ" "$@"; }
  t "DMZ → gateway DMZ"                    ok R ping -c1 -W2 "$GW_DMZ"
  t "DMZ → Internet HTTPS"                 ok R "curl -s -m5 -o /dev/null https://debian.org"
  t "DMZ → PostgreSQL interne (REFUSÉ)"    ko R nc -z -w2 "$IP_SRV" 5432
  t "DMZ → SSH interne (REFUSÉ)"           ko R nc -z -w2 "$IP_SRV" 22
  [[ -n "$IP_WIN" ]] && t "DMZ → RDP Windows (REFUSÉ)" ko R nc -z -w2 "$IP_WIN" 3389
else
  printf "  ${YEL}!!${NC} SSH vers %s indisponible — tests DMZ ignorés\n" "$IP_DMZ"
fi

printf "\n${BLU}── MTU (attendu : %s) ──${NC}\n" "$MTU"
# On ENCADRE le MTU : la charge utile vaut MTU - 28 (20 o d'en-tête IP + 8 d'ICMP).
#   · MTU - 28      → paquet de la taille exacte du MTU   → doit passer
#   · MTU - 27      → un octet de trop                    → doit échouer
# Tester « -s 1473 » ne prouverait rien : ça échoue déjà sur un Ethernet à 1500.
OKSZ=$(( MTU - 28 )); KOSZ=$(( MTU - 27 ))
t "paquet de $MTU o (charge $OKSZ), DF"          ok ping -M do -s "$OKSZ" -c1 -W2 1.1.1.1
t "paquet de $((MTU+1)) o (charge $KOSZ), DF"    ko ping -M do -s "$KOSZ" -c1 -W2 1.1.1.1

printf "\n${BLU}══ Résultat : %d réussis, %d échoués ══${NC}\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  cat <<'EOF'

  Pistes :
    · un test « refusé » qui passe   → une règle ACCEPT trop large, ou placée trop haut
    · un test « ok » qui échoue      → policy_forward DROP sans règle correspondante
    · les règles VNet sans effet     → nftables non activé (host.fw : nftables: 1)
    · le test MTU bas qui échoue     → MTU de la zone ou mtu=1 sur la carte virtio
    · le test MTU haut qui PASSE     → mauvais --mtu (1450 en EVPN, 1500 sinon)

EOF
  exit 1
fi
echo
