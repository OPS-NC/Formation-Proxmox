#!/usr/bin/env bash
# Fabrique un template Proxmox à partir d'une cloud-image.
# À exécuter SUR LE NŒUD PROXMOX, en root.
#
#   ./build-template.sh --eleve 3 --os debian13   --vmid 390
#   ./build-template.sh --eleve 3 --os ubuntu2604 --vmid 391
#   ./build-template.sh --eleve 3 --os rocky10    --vmid 392
set -euo pipefail

# ─── Valeurs par défaut ──────────────────────────────────────────────────────
ELEVE=""; OS=""; VMID=""
STORAGE="local-lvm"
BRIDGE="vmbr0"
DISK_SIZE="20G"
CORES=2
MEMORY=2048
CIUSER="eleve"
CIPASS="Formation2026!"
SSHKEYS="/root/.ssh/authorized_keys"
TZ_LAB="Pacific/Noumea"
IMGDIR="/var/lib/vz/template/cloudimg"
FORCE=0

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
info() { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YEL}/!\\${NC} %s\n" "$*"; }
die()  { printf "${RED}ERREUR:${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --eleve $N --os <debian13|ubuntu2604|rocky10> --vmid ID [options]

Options :
  --eleve $N          numéro d'élève (1-6)              [requis]
  --os NAME          debian13 | ubuntu2604 | rocky10   [requis]
  --vmid ID          identifiant du template           [requis]
  --storage NAME     stockage des disques              [$STORAGE]
  --bridge NAME      bridge ou VNet                    [$BRIDGE]
  --disk-size SIZE   taille finale du disque           [$DISK_SIZE]
  --cores N          vCPU                              [$CORES]
  --memory MB        RAM                               [$MEMORY]
  --force            écrase un VMID existant
  -h, --help         cette aide
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eleve) ELEVE="$2"; shift 2 ;;
    --os) OS="$2"; shift 2 ;;
    --vmid) VMID="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *) die "option inconnue : $1" ;;
  esac
done

[[ -n "$ELEVE" && -n "$OS" && -n "$VMID" ]] || usage
[[ $EUID -eq 0 ]] || die "à exécuter en root sur le nœud Proxmox"
command -v qm >/dev/null || die "commande qm introuvable — êtes-vous bien sur un nœud Proxmox ?"

# ─── Catalogue d'images ──────────────────────────────────────────────────────
case "$OS" in
  debian13)
    URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    FILE="debian-13-genericcloud-amd64.qcow2"; NAME="tpl-debian13-e${ELEVE}"
    PKGS="qemu-guest-agent,curl,vim,htop,ca-certificates,python3"
    EXTRA_CMD="systemctl enable qemu-guest-agent" ;;
  ubuntu2604)
    URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    FILE="ubuntu-26.04-server-cloudimg-amd64.img"; NAME="tpl-ubuntu2604-e${ELEVE}"
    PKGS="qemu-guest-agent,curl,vim,htop,ca-certificates,python3"
    EXTRA_CMD="systemctl enable qemu-guest-agent" ;;
  rocky10)
    URL="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
    FILE="Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"; NAME="tpl-rocky10-e${ELEVE}"
    PKGS="qemu-guest-agent,curl,vim,python3"
    # firewalld est actif par défaut sur Rocky : on filtre côté Proxmox (TP 09)
    EXTRA_CMD="systemctl enable qemu-guest-agent; systemctl disable firewalld || true" ;;
  *) die "OS inconnu : $OS" ;;
esac

# ─── Garde-fous ──────────────────────────────────────────────────────────────
if qm status "$VMID" &>/dev/null; then
  [[ $FORCE -eq 1 ]] || die "le VMID $VMID existe déjà (utilisez --force)"
  warn "suppression du VMID $VMID existant"
  qm stop "$VMID" &>/dev/null || true; sleep 2
  qm destroy "$VMID" --purge
fi

command -v virt-customize >/dev/null || { info "installation de libguestfs-tools"; apt-get install -y -q libguestfs-tools; }

# ─── 1. Télécharger l'image ──────────────────────────────────────────────────
mkdir -p "$IMGDIR"
if [[ ! -f "$IMGDIR/$FILE" ]]; then
  info "téléchargement de $FILE"
  curl -fL --progress-bar -o "$IMGDIR/$FILE" "$URL" || die "téléchargement échoué : $URL"
else
  info "image déjà présente : $IMGDIR/$FILE"
fi

WORK="/tmp/tpl-${VMID}-$$.qcow2"
trap 'rm -f "$WORK"' EXIT
cp "$IMGDIR/$FILE" "$WORK"

# ─── 2. Personnaliser l'image hors ligne ─────────────────────────────────────
info "injection des paquets et de la configuration (virt-customize)"
virt-customize -a "$WORK" \
  --install "$PKGS" \
  --timezone "$TZ_LAB" \
  --run-command "$EXTRA_CMD" \
  --run-command 'echo "PermitRootLogin prohibit-password" > /etc/ssh/sshd_config.d/10-lab.conf || true' \
  --truncate /etc/machine-id     # ⭐ sinon tous les clones envoient le même DUID DHCP → même bail

# ─── 3. Créer la VM support ──────────────────────────────────────────────────
info "création de la VM $VMID ($NAME)"
qm create "$VMID" \
  --name "$NAME" \
  --pool "eleve${ELEVE}" \
  --ostype l26 \
  --machine q35 \
  --cpu x86-64-v2-AES \
  --cores "$CORES" --sockets 1 \
  --memory "$MEMORY" --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${BRIDGE},firewall=1,mtu=1" \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --serial0 socket --vga serial0 \
  --numa 1 \
  --description "Template ${OS} — élève ${ELEVE} — généré par build-template.sh"

# ─── 4. Importer le disque ───────────────────────────────────────────────────
info "import du disque dans $STORAGE"
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${WORK},discard=on,ssd=1,iothread=1" >/dev/null

# ─── 5. Cloud-init ───────────────────────────────────────────────────────────
info "configuration cloud-init"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" >/dev/null
qm set "$VMID" --boot order='scsi0' >/dev/null
qm set "$VMID" \
  --ciuser "$CIUSER" \
  --cipassword "$(openssl passwd -6 "$CIPASS")" \
  --ciupgrade 1 \
  --searchdomain lab.local \
  --ipconfig0 ip=dhcp >/dev/null
[[ -f "$SSHKEYS" ]] && qm set "$VMID" --sshkeys "$SSHKEYS" >/dev/null || warn "$SSHKEYS absent : aucune clé injectée"

# ─── 6. Agrandir et sceller ──────────────────────────────────────────────────
info "agrandissement du disque à $DISK_SIZE"
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null

info "conversion en template"
qm template "$VMID"

printf "\n${GREEN}✔ Template %s (VMID %s) prêt${NC}\n\n" "$NAME" "$VMID"
qm config "$VMID" | grep -E '^(name|cores|memory|scsi0|ide2|net0|cpu|agent)'
cat <<EOF

Pour cloner :
  qm clone $VMID <nouveau-vmid> --name <nom> --pool eleve${ELEVE}
  qm set <nouveau-vmid> --net0 virtio,bridge=vint,firewall=1,mtu=1 --ipconfig0 ip=dhcp
  qm start <nouveau-vmid>
EOF
