#!/usr/bin/env bash
# =============================================================================
# uninstall-k3s.sh
# Uninstal K3s beserta seluruh data, konfigurasi, dan komponen terkait.
# Mendukung uninstal role server maupun agent.
#
# Penggunaan:
#   sudo ./uninstall-k3s.sh [OPTIONS]
#
# Opsi:
#   --role    <server|agent>   Role node yang akan diuninstal (default: autodetect)
#   --purge                    Hapus juga data persistent (volumes, data dir)
#   --yes                      Lewati konfirmasi interaktif
#   --help                     Tampilkan bantuan ini
#
# PERINGATAN:
#   Skrip ini akan MENGHAPUS PERMANEN semua data K3s termasuk konfigurasi
#   kluster, container yang berjalan, dan data persistent jika --purge digunakan.
# =============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

# --- Default ---
ROLE="auto"
PURGE=false
YES=false

# --- Warna Terminal ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)   ROLE="$2";    shift 2 ;;
      --purge)  PURGE=true;   shift ;;
      --yes)    YES=true;     shift ;;
      --help|-h) usage ;;
      *)
        log_error "Argumen tidak dikenal: $1"
        exit 1
        ;;
    esac
  done
}

detect_role() {
  if [[ "${ROLE}" == "auto" ]]; then
    if systemctl list-units --type=service 2>/dev/null | grep -q "k3s.service"; then
      ROLE="server"
    elif systemctl list-units --type=service 2>/dev/null | grep -q "k3s-agent.service"; then
      ROLE="agent"
    else
      log_warn "Tidak dapat mendeteksi role K3s secara otomatis. Menggunakan: server"
      ROLE="server"
    fi
  fi
  log_info "Role terdeteksi: ${ROLE}"
}

confirm_uninstall() {
  if [[ "${YES}" == true ]]; then
    return 0
  fi

  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║              PERINGATAN: TINDAKAN DESTRUKTIF           ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Skrip ini akan menghapus K3s (role: ${BOLD}${ROLE}${NC}) beserta:"
  echo "  - Semua container yang sedang berjalan"
  echo "  - Service systemd K3s"
  echo "  - Konfigurasi jaringan (CNI, iptables rules)"
  echo "  - Kubeconfig"
  if [[ "${PURGE}" == true ]]; then
    echo -e "  ${RED}- DATA PERSISTENT (volumes, images) [--purge aktif]${NC}"
  fi
  echo ""
  read -r -p "Ketik 'ya' untuk melanjutkan: " CONFIRM
  if [[ "${CONFIRM}" != "ya" ]]; then
    log_info "Uninstal dibatalkan."
    exit 0
  fi
}

run_uninstall() {
  log_step "Menjalankan uninstal K3s..."

  local UNINSTALL_SCRIPT_SERVER="/usr/local/bin/k3s-uninstall.sh"
  local UNINSTALL_SCRIPT_AGENT="/usr/local/bin/k3s-agent-uninstall.sh"

  if [[ "${ROLE}" == "server" ]] && [[ -f "${UNINSTALL_SCRIPT_SERVER}" ]]; then
    log_info "Mengeksekusi ${UNINSTALL_SCRIPT_SERVER}..."
    "${UNINSTALL_SCRIPT_SERVER}"
    log_info "Uninstal server K3s selesai."

  elif [[ "${ROLE}" == "agent" ]] && [[ -f "${UNINSTALL_SCRIPT_AGENT}" ]]; then
    log_info "Mengeksekusi ${UNINSTALL_SCRIPT_AGENT}..."
    "${UNINSTALL_SCRIPT_AGENT}"
    log_info "Uninstal agent K3s selesai."

  else
    log_warn "Skrip uninstal bawaan K3s tidak ditemukan. Melakukan uninstal manual..."
    manual_uninstall
  fi
}

manual_uninstall() {
  log_step "Uninstal manual K3s..."

  # Hentikan dan disable service
  for svc in k3s k3s-agent; do
    if systemctl list-units --type=service 2>/dev/null | grep -q "${svc}.service"; then
      systemctl stop "${svc}" 2>/dev/null || true
      systemctl disable "${svc}" 2>/dev/null || true
      log_info "Service ${svc} dihentikan dan di-disable."
    fi
  done

  # Hapus binary K3s
  rm -f /usr/local/bin/k3s
  log_info "Binary K3s dihapus."

  # Hapus service unit files
  rm -f /etc/systemd/system/k3s.service
  rm -f /etc/systemd/system/k3s-agent.service
  rm -f /etc/systemd/system/k3s*.env
  systemctl daemon-reload

  # Hapus konfigurasi kernel yang ditambahkan skrip instalasi
  rm -f /etc/sysctl.d/99-k3s.conf
  rm -f /etc/modules-load.d/k3s.conf

  # Bersihkan iptables rules K3s
  if command -v iptables &>/dev/null; then
    log_info "Membersihkan iptables rules K3s..."
    iptables-save 2>/dev/null | grep -v "KUBE\|CNI\|k3s\|flannel" | iptables-restore 2>/dev/null || true
    ip6tables-save 2>/dev/null | grep -v "KUBE\|CNI\|k3s\|flannel" | ip6tables-restore 2>/dev/null || true
  fi

  # Hapus network interfaces K3s
  for iface in flannel.1 cni0 kube-bridge; do
    if ip link show "${iface}" &>/dev/null; then
      ip link delete "${iface}" 2>/dev/null || true
      log_info "Interface ${iface} dihapus."
    fi
  done

  log_info "Uninstal manual selesai."
}

purge_data() {
  if [[ "${PURGE}" != true ]]; then
    return 0
  fi

  log_step "Menghapus data persistent K3s (--purge)..."

  local DATA_DIRS=(
    "/var/lib/rancher/k3s"
    "/var/lib/kubelet"
    "/etc/rancher"
    "/etc/cni"
    "/opt/cni"
    "/run/k3s"
    "/run/flannel"
    "/var/log/pods"
    "/var/log/containers"
  )

  for dir in "${DATA_DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
      rm -rf "${dir}"
      log_info "Direktori dihapus: ${dir}"
    fi
  done

  # Hapus kubeconfig
  local KUBE_CONFIGS=("${HOME}/.kube/config")
  if [[ -n "${SUDO_USER:-}" ]]; then
    local SUDO_HOME
    SUDO_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    KUBE_CONFIGS+=("${SUDO_HOME}/.kube/config")
  fi

  for kc in "${KUBE_CONFIGS[@]}"; do
    if [[ -f "${kc}" ]]; then
      rm -f "${kc}"
      log_info "Kubeconfig dihapus: ${kc}"
    fi
  done

  log_warn "Data persistent K3s telah dihapus secara permanen."
}

main() {
  echo -e "\n${BOLD}${RED}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║      K3s Uninstaller                 ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════╝${NC}\n"

  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Skrip ini harus dijalankan sebagai root. Gunakan: sudo $0"
    exit 1
  fi

  parse_args "$@"
  detect_role
  confirm_uninstall
  run_uninstall
  purge_data

  log_info "Proses uninstal K3s selesai."
  [[ "${PURGE}" == true ]] && log_warn "Semua data persistent telah dihapus."
}

main "$@"
