#!/usr/bin/env bash
# Prépare un volume logique dédié à un OSD Ceph sur le disque système (TP 18).
# À exécuter SUR LE NŒUD PROXMOX, en root.
#
#   ./ceph-prep-lvm.sh --check              # diagnostic seul, ne modifie RIEN
#   ./ceph-prep-lvm.sh --size 60G           # chemin A : espace libre disponible
#   ./ceph-prep-lvm.sh --size 120G --recreate-thinpool 200G --i-know   # chemin B ⚠
set -euo pipefail

VG="pve"
THINPOOL="data"
LVNAME="ceph-osd"
SIZE=""
RECREATE=""
CONFIRM=0
CHECK_ONLY=0

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
info(){ printf "${GREEN}==>${NC} %s\n" "$*"; }
warn(){ printf "${YEL}/!\\${NC} %s\n" "$*"; }
die(){  printf "${RED}ERREUR:${NC} %s\n" "$*" >&2; exit 1; }
titre(){ printf "\n${BLU}══ %s ══${NC}\n" "$1"; }

usage() {
  cat <<EOF
Usage:
  $0 --check
  $0 --size <taille>                                  (chemin A)
  $0 --size <taille> --recreate-thinpool <taille> --i-know   (chemin B, DESTRUCTIF)

Options :
  --check                     diagnostic seul, aucune modification
  --size <taille>             taille du LV Ceph (ex. 60G, 120G)
  --recreate-thinpool <t>     détruit et recrée $VG/$THINPOOL à cette taille  ⚠
  --i-know                    confirme que vous avez compris le caractère destructif
  --vg <nom>                  groupe de volumes             [$VG]
  --thinpool <nom>            nom du pool thin              [$THINPOOL]
  --lv <nom>                  nom du LV Ceph                [$LVNAME]
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --size) SIZE="$2"; shift 2 ;;
    --recreate-thinpool) RECREATE="$2"; shift 2 ;;
    --i-know) CONFIRM=1; shift ;;
    --vg) VG="$2"; shift 2 ;;
    --thinpool) THINPOOL="$2"; shift 2 ;;
    --lv) LVNAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "option inconnue : $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "à exécuter en root"
command -v vgs >/dev/null || die "LVM introuvable"

# ─── Diagnostic ──────────────────────────────────────────────────────────────
titre "Disques physiques"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | sed 's/^/  /'

titre "Groupe de volumes $VG"
vgs -o vg_name,vg_size,vg_free --units g "$VG" | sed 's/^/  /'

titre "Volumes logiques"
lvs -o lv_name,lv_size,pool_lv,data_percent,metadata_percent --units g "$VG" | sed 's/^/  /'

FREE_G=$(vgs --noheadings --units g -o vg_free "$VG" | tr -dc '0-9.' | cut -d. -f1)
FREE_G=${FREE_G:-0}
info "Espace non alloué dans $VG : ${FREE_G} Go"

titre "Disques entiers libres (idéaux pour Ceph)"
FOUND_DISK=0
while read -r name type; do
  [[ "$type" == "disk" ]] || continue
  if ! lsblk -no NAME "/dev/$name" | tail -n +2 | grep -q .; then
    if ! pvs "/dev/$name" &>/dev/null; then
      printf "  ${GREEN}%s${NC} — libre → chemin C : pveceph osd create /dev/%s\n" "$name" "$name"
      FOUND_DISK=1
    fi
  fi
done < <(lsblk -dno NAME,TYPE)
[[ $FOUND_DISK -eq 0 ]] && echo "  (aucun)"

titre "Volume Ceph déjà présent ?"
if lvs "$VG/$LVNAME" &>/dev/null; then
  lvs -o lv_name,lv_size,lv_tags "$VG/$LVNAME" | sed 's/^/  /'
  info "$VG/$LVNAME existe déjà"
else
  echo "  (non)"
fi

titre "Verdict"
if [[ $FOUND_DISK -eq 1 ]]; then
  cat <<EOF
  ${GREEN}Chemin C${NC} — un disque entier est libre. C'est la meilleure option :
      pveceph osd create /dev/<disque>
EOF
elif [[ "$FREE_G" -ge 20 ]]; then
  cat <<EOF
  ${GREEN}Chemin A${NC} — ${FREE_G} Go non alloués dans le VG. Aucune destruction nécessaire :
      $0 --size ${FREE_G}G
EOF
else
  cat <<EOF
  ${YEL}Chemin B${NC} — le VG est plein. Un pool LVM-thin NE PEUT PAS être réduit.
  Il faut le détruire et le recréer plus petit :

    1. Sauvegarder tous les guests vers PBS   (TP 15)  ← OBLIGATOIRE
    2. Vérifier les sauvegardes (Verify)
    3. Détruire les guests
    4. $0 --size 120G --recreate-thinpool 200G --i-know
    5. Restaurer les guests depuis PBS
EOF
fi
echo

[[ $CHECK_ONLY -eq 1 ]] && exit 0
[[ -n "$SIZE" ]] || die "--size est requis (ou utilisez --check)"

# ─── Chemin B : recréer le pool thin ─────────────────────────────────────────
if [[ -n "$RECREATE" ]]; then
  [[ $CONFIRM -eq 1 ]] || die "--recreate-thinpool exige --i-know : cette opération DÉTRUIT $VG/$THINPOOL"

  titre "Contrôles avant destruction"
  VMS=$(qm list 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')
  CTS=$(pct list 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')
  [[ -n "${VMS// }" ]] && die "des VM existent encore : $VMS — sauvegardez puis détruisez-les"
  [[ -n "${CTS// }" ]] && die "des conteneurs existent encore : $CTS — sauvegardez puis détruisez-les"

  VOLS=$(lvs --noheadings -o lv_name,pool_lv "$VG" | awk -v p="$THINPOOL" '$2==p{print $1}' | tr '\n' ' ')
  [[ -n "${VOLS// }" ]] && die "des volumes subsistent dans $THINPOOL : $VOLS"

  warn "DERNIÈRE CHANCE : $VG/$THINPOOL va être détruit puis recréé à $RECREATE"
  read -r -p "Tapez DETRUIRE pour confirmer : " ans
  [[ "$ans" == "DETRUIRE" ]] || { echo "Annulé."; exit 0; }

  info "sauvegarde de l'état LVM dans /root/pre-ceph/"
  mkdir -p /root/pre-ceph
  lvs > /root/pre-ceph/lvs-avant.txt
  vgs > /root/pre-ceph/vgs-avant.txt
  cp /etc/pve/storage.cfg /root/pre-ceph/ 2>/dev/null || true

  info "désactivation du stockage local-lvm"
  pvesm set local-lvm --disable 1 2>/dev/null || warn "impossible de désactiver local-lvm"

  info "suppression du pool $VG/$THINPOOL"
  lvremove -y "$VG/$THINPOOL"

  info "recréation du pool thin à $RECREATE"
  lvcreate --type thin-pool -n "$THINPOOL" -L "$RECREATE" "$VG"

  info "réactivation du stockage local-lvm"
  pvesm set local-lvm --disable 0 2>/dev/null || true
fi

# ─── Créer le LV Ceph ────────────────────────────────────────────────────────
titre "Création du volume Ceph"
if lvs "$VG/$LVNAME" &>/dev/null; then
  warn "$VG/$LVNAME existe déjà, rien à faire"
else
  lvcreate -n "$LVNAME" -L "$SIZE" "$VG"
  info "$VG/$LVNAME créé ($SIZE)"
fi

lvs -o lv_name,lv_size,pool_lv,data_percent --units g "$VG" | sed 's/^/  /'
vgs -o vg_name,vg_size,vg_free --units g "$VG" | sed 's/^/  /'

FREE_AFTER=$(vgs --noheadings --units g -o vg_free "$VG" | tr -dc '0-9.' | cut -d. -f1)
[[ "${FREE_AFTER:-0}" -lt 5 ]] && warn "il ne reste presque plus d'espace libre dans le VG — gardez toujours 5 à 10 % de marge"

cat <<EOF

${GREEN}✔ Prêt.${NC} Créez maintenant l'OSD (en CLI : l'interface web ne propose pas les LV) :

    pveceph osd create /dev/$VG/$LVNAME

  Si pveceph refuse le volume logique, passez par la commande Ceph native :

    mkdir -p /var/lib/ceph/bootstrap-osd
    ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
    chown -R ceph:ceph /var/lib/ceph/bootstrap-osd
    ceph-volume lvm create --data $VG/$LVNAME --bluestore
    ceph-volume lvm activate --all

  Puis vérifiez :  ceph -s && ceph osd tree

EOF
