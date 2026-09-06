#!/usr/bin/env bash
# Recette TP 09/12 uniquement, depuis le poste Linux 172.30.30.0/24.
# Lecture seule : ne lance aucun listener et ne modifie aucune règle.
set -uo pipefail

INT=""; DMZ=""; SERVICES=""; EXPORTER=""
INT_USER=eleve; DMZ_USER=root; SERVICES_USER=eleve
PASS=0; FAIL=0
usage() {
  echo "Usage: $0 --int IP --dmz IP [--int-user eleve] [--dmz-user root]"
  echo "       [--services IP --exporter IP] [--services-user eleve]"
  echo "Préparer SSH, nc, curl, ip, les services et le listener DMZ:8080 (TP 09 §7)."
}
die() { echo "ERREUR : $*" >&2; exit 2; }
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --int|--dmz|--services|--exporter|--int-user|--dmz-user|--services-user)
      (($# >= 2)) || die "valeur manquante pour $1"
      case "$1" in
        --int) INT=$2 ;; --dmz) DMZ=$2 ;; --services) SERVICES=$2 ;;
        --exporter) EXPORTER=$2 ;; --int-user) INT_USER=$2 ;;
        --dmz-user) DMZ_USER=$2 ;; --services-user) SERVICES_USER=$2 ;;
      esac
      shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
[[ -n $INT && -n $DMZ ]] || die "--int et --dmz sont requis"
[[ -z $SERVICES && -z $EXPORTER || -n $SERVICES && -n $EXPORTER ]] || die "--services et --exporter vont ensemble"
ipv4() {
  local ip=$1 octet
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for octet in $ip; do ((10#$octet <= 255)) || return 1; done
}
for ip in "$INT" "$DMZ" "$SERVICES" "$EXPORTER"; do
  [[ -z $ip ]] || ipv4 "$ip" || die "IPv4 invalide : $ip"
done
[[ $INT == 10.10.10.* && $DMZ == 10.10.20.* ]] || die "ce script ne teste que le standalone 10.10.10/24 et 10.10.20/24"
[[ -z $SERVICES || $SERVICES == 10.10.30.* && $EXPORTER == 10.10.10.* ]] || die "SERVICES doit être dans 10.10.30/24 et exporter dans INTERNAL"
for user in "$INT_USER" "$DMZ_USER" "$SERVICES_USER"; do
  [[ $user =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die "compte SSH invalide"
done
for cmd in ssh nc ip grep; do command -v "$cmd" >/dev/null || die "outil local absent : $cmd"; done
ip -4 -o addr show | grep -Eq ' inet 172\.30\.30\.[0-9]+/24 ' || die "lancer depuis le poste Linux du LAN salle /24"

# Les commandes distantes utilisent des arguments simples validés ci-dessus.
# Pas de désactivation de la vérification des clés hôtes, ni de copie de clé privée.
remote() {
  local target=$1; shift
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$target" "$@"
}
I() { remote "$INT_USER@$INT" "$@"; }
D() { remote "$DMZ_USER@$DMZ" "$@"; }
S() { remote "$SERVICES_USER@$SERVICES" "$@"; }

required() { # <description> <commande...> : arrêt, pas faux succès, si prérequis absent
  local label=$1; shift
  "$@" >/dev/null 2>&1 || die "$label (SSH, outil, listener ou route à vérifier)"
}
probe() { # <description> ok|deny <commande...>
  local label=$1 want=$2 rc=0; shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  # nc OpenBSD retourne 1 pour une connexion impossible. SSH=255 / outil=127
  # et les autres erreurs ne constituent jamais une preuve de refus firewall.
  if [[ $want == ok && $rc == 0 || $want == deny && $rc == 1 ]]; then
    printf 'PASS %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf 'FAIL %s (attendu=%s, code=%s)\n' "$label" "$want" "$rc"
    FAIL=$((FAIL + 1))
  fi
}
for ip in "$INT" "$DMZ" "$SERVICES" "$EXPORTER"; do
  [[ -z $ip ]] && continue
  ip -4 route get "$ip" | grep -Eq ' src 172\.30\.30\.[0-9]+( |$)' || die "la route vers $ip ne sélectionne pas une source du LAN salle"
  required "LAN → $ip:22" nc -z -w3 "$ip" 22
done
required "SSH/outils INTERNAL" I 'command -v nc && command -v curl && command -v ip && command -v ping'
required "SSH/outils DMZ" D 'command -v nc && command -v curl && command -v ip && command -v ping'
required "adresse de la source INTERNAL" I "ip -4 -o addr show | grep -F ' $INT/'"
required "adresse de la source DMZ" D "ip -4 -o addr show | grep -F ' $DMZ/'"
required "nginx DMZ:80" D nc -z -w3 "$DMZ" 80
required "listener de contrôle DMZ:8080" D nc -z -w3 "$DMZ" 8080
required "PostgreSQL INTERNAL:5432 accessible du LAN" nc -z -w3 "$INT" 5432
probe 'LAN → INTERNAL SSH authentifié' ok I hostname
probe 'LAN → DMZ SSH authentifié' ok D hostname
probe 'INTERNAL → gateway' ok I ping -c1 -W2 10.10.10.1
probe 'DMZ → gateway' ok D ping -c1 -W2 10.10.20.1
probe 'INTERNAL → Internet HTTPS + DNS' ok I curl -fsS -o /dev/null --connect-timeout 3 --max-time 10 https://debian.org
probe 'DMZ → Internet HTTPS + DNS' ok D curl -fsS -o /dev/null --connect-timeout 3 --max-time 10 https://debian.org
probe 'INTERNAL → DMZ HTTP' ok I nc -z -w3 "$DMZ" 80
probe 'INTERNAL → DMZ SSH' ok I nc -z -w3 "$DMZ" 22
probe 'INTERNAL → DMZ:8080 interdit (listener contrôlé)' deny I nc -z -w3 "$DMZ" 8080
probe 'DMZ → INTERNAL SSH interdit' deny D nc -z -w3 "$INT" 22
probe 'DMZ → INTERNAL PostgreSQL interdit' deny D nc -z -w3 "$INT" 5432

if [[ -n $SERVICES ]]; then
  required "SSH/outils SERVICES" S 'command -v nc && command -v curl && command -v ip'
  required "adresse de la source SERVICES" S "ip -4 -o addr show | grep -F ' $SERVICES/'"
  required "listener de contrôle SERVICES:8080" S nc -z -w3 "$SERVICES" 8080
  probe 'LAN → SERVICES SSH authentifié' ok S hostname
  probe 'SERVICES → Internet HTTPS + DNS' ok S curl -fsS -o /dev/null --connect-timeout 3 --max-time 10 https://debian.org
  probe 'SERVICES → INTERNAL SSH' ok S nc -z -w3 "$INT" 22
  probe 'SERVICES → exporter INTERNAL:9100' ok S nc -z -w3 "$EXPORTER" 9100
  probe 'SERVICES → INTERNAL PostgreSQL interdit' deny S nc -z -w3 "$INT" 5432
  probe 'SERVICES → DMZ HTTP interdit' deny S nc -z -w3 "$DMZ" 80
  probe 'INTERNAL → SERVICES SSH' ok I nc -z -w3 "$SERVICES" 22
  probe 'INTERNAL → SERVICES:8080 interdit (listener contrôlé)' deny I nc -z -w3 "$SERVICES" 8080
  probe 'DMZ → SERVICES SSH interdit' deny D nc -z -w3 "$SERVICES" 22
fi
printf '\nRésultat : %d réussis, %d échoués (aucun test obligatoire ignoré).\n' "$PASS" "$FAIL"
echo 'Un refus TCP ne localise pas le filtre : confirmer avec les logs/compteurs nftables.'
echo 'Cette recette ne couvre ni IPv6, ni DHCP après reboot, ni MTU, ni tous les invités.'
((FAIL == 0))
