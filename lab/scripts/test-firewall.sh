#!/usr/bin/env bash
# Vérifie la matrice de flux des TP 09 / 12 / 16 depuis un poste de rebond.
# À exécuter depuis une VM de la zone INTERNE, ou depuis le nœud avec --via-node.
#
#   ./test-firewall.sh --eleve 3 --int 10.3.10.101 --dmz 10.3.20.101 --win 10.3.10.102
set -uo pipefail

ELEVE=""; IP_INT=""; IP_DMZ=""; IP_WIN=""; IP_SRV=""
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
PASS=0; FAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eleve) ELEVE="$2"; shift 2 ;;
    --int)   IP_INT="$2"; shift 2 ;;
    --dmz)   IP_DMZ="$2"; shift 2 ;;
    --win)   IP_WIN="$2"; shift 2 ;;
    --srv)   IP_SRV="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 --eleve N --int IP --dmz IP [--win IP] [--srv IP]"; exit 0 ;;
    *) echo "option inconnue : $1"; exit 1 ;;
  esac
done
[[ -n "$ELEVE" && -n "$IP_INT" && -n "$IP_DMZ" ]] || { echo "--eleve, --int et --dmz sont requis"; exit 1; }
IP_SRV="${IP_SRV:-$IP_INT}"

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

printf "${BLU}Tests de la matrice de flux — élève %s${NC}\n" "$ELEVE"
printf "  interne=%s  dmz=%s  windows=%s\n" "$IP_INT" "$IP_DMZ" "${IP_WIN:-n/a}"

printf "\n${BLU}── Depuis la zone INTERNE ──${NC}\n"
t "gateway interne joignable"            ok ping_test "10.${ELEVE}.10.1"
t "Internet (ICMP)"                      ok ping_test 9.9.9.9
t "résolution DNS"                       ok getent hosts debian.org
t "interne → DMZ : HTTP 80"              ok nc_test "$IP_DMZ" 80
t "interne → DMZ : SSH 22"               ok nc_test "$IP_DMZ" 22
t "interne → DMZ : MySQL 3306 (refusé)"  ko nc_test "$IP_DMZ" 3306
t "interne → DMZ : 8080 (refusé)"        ko nc_test "$IP_DMZ" 8080
[[ -n "$IP_WIN" ]] && t "interne → Windows : RDP 3389" ok nc_test "$IP_WIN" 3389

printf "\n${BLU}── Depuis la DMZ (rebond SSH) ──${NC}\n"
if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
       "eleve@$IP_DMZ" true 2>/dev/null; then
  R() { ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "eleve@$IP_DMZ" "$@"; }
  t "DMZ → gateway DMZ"                    ok R ping -c1 -W2 "10.${ELEVE}.20.1"
  t "DMZ → Internet HTTPS"                 ok R "curl -s -m5 -o /dev/null https://debian.org"
  t "DMZ → PostgreSQL interne (REFUSÉ)"    ko R nc -z -w2 "$IP_SRV" 5432
  t "DMZ → SSH interne (REFUSÉ)"           ko R nc -z -w2 "$IP_SRV" 22
  [[ -n "$IP_WIN" ]] && t "DMZ → RDP Windows (REFUSÉ)" ko R nc -z -w2 "$IP_WIN" 3389
else
  printf "  ${YEL}!!${NC} SSH vers %s indisponible — tests DMZ ignorés\n" "$IP_DMZ"
fi

printf "\n${BLU}── MTU (important en EVPN) ──${NC}\n"
t "paquet 1422 octets, DF"               ok ping -M do -s 1422 -c1 -W2 9.9.9.9
t "paquet 1473 octets, DF (doit échouer)" ko ping -M do -s 1473 -c1 -W2 9.9.9.9

printf "\n${BLU}══ Résultat : %d réussis, %d échoués ══${NC}\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  cat <<'EOF'

  Pistes :
    · un test « refusé » qui passe   → une règle ACCEPT trop large, ou placée trop haut
    · un test « ok » qui échoue      → policy_forward DROP sans règle correspondante
    · les règles VNet sans effet     → nftables non activé (host.fw : nftables: 1)
    · le test MTU 1422 qui échoue    → MTU de la zone ou mtu=1 sur la carte virtio

EOF
  exit 1
fi
echo
