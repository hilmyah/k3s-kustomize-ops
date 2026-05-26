#!/usr/bin/env bash
# =============================================================================
# install-k3s.sh
# Instalasi K3s multi-distro (Debian, Ubuntu, RHEL/CentOS, Fedora, openSUSE,
# Arch Linux) dengan opsi konfigurasi modular.
#
# Penggunaan:
#   sudo ./install-k3s.sh [OPTIONS]
#
# Opsi:
#   --role        <server|agent>     Role node (default: server)
#   --server-url  <URL>              URL K3s server, wajib untuk role agent
#   --token       <TOKEN>            Token join cluster, wajib untuk role agent
#   --disable     <komponen,...>     Komponen bawaan yang dinonaktifkan
#                                    (traefik, servicelb, local-storage, metrics-server)
#   --ingress     <nginx|traefik>    Ingress controller yang digunakan (default: traefik)
#   --tls-san     <IP/domain,...>    SAN tambahan untuk sertifikat TLS API server
#   --data-dir    <path>             Direktori data K3s (default: /var/lib/rancher/k3s)
#   --channel     <stable|latest>    Channel rilis K3s (default: stable)
#   --dry-run                        Tampilkan konfigurasi tanpa mengeksekusi instalasi
#   --help                           Tampilkan bantuan ini
#
# Contoh:
#   sudo ./install-k3s.sh --ingress nginx --tls-san 192.168.1.10,k3s.example.com
#   sudo ./install-k3s.sh --role agent --server-url https://192.168.1.10:6443 --token <TOKEN>
# =============================================================================

set -euo pipefail

# --- Konstanta & Default ---
readonly SCRIPT_NAME="$(basename "$0")"
readonly K3S_INSTALL_URL="https://get.k3s.io"
readonly KUBECONFIG_DIR="/etc/rancher/k3s"
readonly KUBECONFIG_FILE="${KUBECONFIG_DIR}/k3s.yaml"
readonly USER_KUBECONFIG="${HOME}/.kube/config"

DEFAULT_ROLE="server"
DEFAULT_CHANNEL="stable"
DEFAULT_INGRESS="traefik"
DEFAULT_DATA_DIR="/var/lib/rancher/k3s"

# --- Variabel Konfigurasi ---
ROLE="${DEFAULT_ROLE}"
SERVER_URL=""
TOKEN=""
DISABLE_COMPONENTS=""
INGRESS="${DEFAULT_INGRESS}"
TLS_SAN=""
DATA_DIR="${DEFAULT_DATA_DIR}"
CHANNEL="${DEFAULT_CHANNEL}"
DRY_RUN=false

# --- Warna Terminal ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# --- Fungsi Logging ---
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }
log_section() { echo -e "\n${CYAN}${BOLD}--- $* ---${NC}"; }

# --- Fungsi Bantuan ---
usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

# --- Deteksi Distro ---
detect_distro() {
  log_step "Mendeteksi distribusi Linux..."

  if [[ ! -f /etc/os-release ]]; then
    log_error "Tidak dapat mendeteksi distro: /etc/os-release tidak ditemukan."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_ID_LIKE="${ID_LIKE:-}"
  DISTRO_VERSION="${VERSION_ID:-}"
  DISTRO_NAME="${PRETTY_NAME:-${NAME:-unknown}}"

  log_info "Distro terdeteksi: ${DISTRO_NAME}"

  # Normalisasi family distro
  case "${DISTRO_ID}" in
    debian|ubuntu|linuxmint|pop)         DISTRO_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol)      DISTRO_FAMILY="rhel" ;;
    fedora)                               DISTRO_FAMILY="fedora" ;;
    opensuse*|sles)                       DISTRO_FAMILY="suse" ;;
    arch|manjaro|endeavouros|garuda)      DISTRO_FAMILY="arch" ;;
    alpine)                               DISTRO_FAMILY="alpine" ;;
    *)
      # Fallback via ID_LIKE
      if [[ "${DISTRO_ID_LIKE}" =~ debian ]]; then       DISTRO_FAMILY="debian"
      elif [[ "${DISTRO_ID_LIKE}" =~ rhel|fedora ]]; then DISTRO_FAMILY="rhel"
      elif [[ "${DISTRO_ID_LIKE}" =~ suse ]]; then        DISTRO_FAMILY="suse"
      elif [[ "${DISTRO_ID_LIKE}" =~ arch ]]; then        DISTRO_FAMILY="arch"
      else
        log_warn "Distro '${DISTRO_ID}' tidak dikenali secara eksplisit, mencoba sebagai generic."
        DISTRO_FAMILY="generic"
      fi
      ;;
  esac

  log_info "Family distro: ${DISTRO_FAMILY}"
}

# --- Pengecekan Prasyarat ---
check_prerequisites() {
  log_step "Memeriksa prasyarat sistem..."

  # Root check
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Skrip ini harus dijalankan sebagai root. Gunakan: sudo $0"
    exit 1
  fi

  # Arsitektur CPU
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64)   K3S_ARCH="amd64" ;;
    aarch64|arm64)  K3S_ARCH="arm64" ;;
    armv7l)         K3S_ARCH="arm" ;;
    *)
      log_error "Arsitektur '${ARCH}' tidak didukung oleh K3s."
      exit 1
      ;;
  esac
  log_info "Arsitektur CPU: ${ARCH} (K3s: ${K3S_ARCH})"

  # RAM minimum (512 MB untuk agent, 1 GB untuk server)
  TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  REQUIRED_RAM_MB=$([[ "${ROLE}" == "server" ]] && echo 1024 || echo 512)

  if [[ "${TOTAL_RAM_MB}" -lt "${REQUIRED_RAM_MB}" ]]; then
    log_warn "RAM terdeteksi: ${TOTAL_RAM_MB} MB. Minimum direkomendasikan: ${REQUIRED_RAM_MB} MB untuk role '${ROLE}'."
  else
    log_info "RAM: ${TOTAL_RAM_MB} MB (memenuhi syarat minimum ${REQUIRED_RAM_MB} MB)"
  fi

  # Dependensi wajib
  local missing_deps=()
  for cmd in curl iptables; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing_deps+=("${cmd}")
    fi
  done

  if [[ "${#missing_deps[@]}" -gt 0 ]]; then
    log_warn "Dependensi berikut tidak ditemukan: ${missing_deps[*]}"
    install_dependencies "${missing_deps[@]}"
  else
    log_info "Semua dependensi wajib tersedia."
  fi

  # Validasi argumen role agent
  if [[ "${ROLE}" == "agent" ]]; then
    [[ -z "${SERVER_URL}" ]] && { log_error "--server-url wajib diisi untuk role agent."; exit 1; }
    [[ -z "${TOKEN}" ]]      && { log_error "--token wajib diisi untuk role agent."; exit 1; }
  fi
}

# --- Instalasi Dependensi ---
install_dependencies() {
  local deps=("$@")
  log_step "Menginstal dependensi: ${deps[*]}..."

  case "${DISTRO_FAMILY}" in
    debian)
      apt-get update -qq
      apt-get install -y --no-install-recommends "${deps[@]}"
      ;;
    rhel|fedora)
      if command -v dnf &>/dev/null; then
        dnf install -y "${deps[@]}"
      else
        yum install -y "${deps[@]}"
      fi
      ;;
    suse)
      zypper install -y "${deps[@]}"
      ;;
    arch)
      pacman -Sy --noconfirm "${deps[@]}"
      ;;
    alpine)
      apk add --no-cache "${deps[@]}"
      ;;
    *)
      log_warn "Tidak dapat menginstal dependensi secara otomatis untuk distro ini. Instal manual: ${deps[*]}"
      ;;
  esac
}

# --- Konfigurasi Firewall ---
configure_firewall() {
  log_step "Mengkonfigurasi firewall..."

  # Deteksi dan konfigurasi firewall yang aktif
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    log_info "Mendeteksi firewalld, membuka port K3s..."
    firewall-cmd --permanent --add-port=6443/tcp   # API Server
    firewall-cmd --permanent --add-port=10250/tcp  # Kubelet metrics
    firewall-cmd --permanent --add-port=8472/udp   # Flannel VXLAN
    firewall-cmd --permanent --add-port=51820/udp  # WireGuard (opsional)
    firewall-cmd --reload
    log_info "Firewalld: port K3s berhasil dibuka."

  elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log_info "Mendeteksi UFW, membuka port K3s..."
    ufw allow 6443/tcp   comment 'K3s API Server'
    ufw allow 10250/tcp  comment 'K3s Kubelet Metrics'
    ufw allow 8472/udp   comment 'K3s Flannel VXLAN'
    ufw allow 51820/udp  comment 'K3s WireGuard (opsional)'
    log_info "UFW: port K3s berhasil dibuka."

  else
    log_info "Tidak ada firewall aktif terdeteksi (firewalld/ufw). Melewati konfigurasi firewall."
    log_warn "Pastikan port berikut dapat diakses secara manual jika menggunakan firewall lain:"
    log_warn "  TCP 6443    - Kubernetes API Server"
    log_warn "  TCP 10250   - Kubelet Metrics"
    log_warn "  UDP 8472    - Flannel VXLAN"
    log_warn "  UDP 51820   - WireGuard (jika diaktifkan)"
  fi
}

# --- Konfigurasi Kernel Modules ---
configure_kernel() {
  log_step "Mengkonfigurasi kernel modules dan sysctl..."

  # Load modules yang diperlukan
  local modules=(br_netfilter overlay nf_conntrack)
  for mod in "${modules[@]}"; do
    if modprobe "${mod}" 2>/dev/null; then
      log_info "Kernel module '${mod}' dimuat."
    else
      log_warn "Gagal memuat kernel module '${mod}' (mungkin sudah built-in)."
    fi
  done

  # Persistensi module
  cat > /etc/modules-load.d/k3s.conf <<EOF
br_netfilter
overlay
nf_conntrack
EOF

  # Konfigurasi sysctl untuk networking
  cat > /etc/sysctl.d/99-k3s.conf <<EOF
# K3s - IPv4/IPv6 forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# K3s - Bridge networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1

# K3s - Connection tracking
net.netfilter.nf_conntrack_max = 524288
EOF

  sysctl --system > /dev/null 2>&1
  log_info "Konfigurasi sysctl diterapkan."
}

# --- Bangun Argumen Instalasi K3s ---
build_install_args() {
  K3S_INSTALL_ARGS=""

  # Tentukan komponen yang di-disable berdasarkan pilihan ingress
  if [[ "${ROLE}" == "server" ]]; then
    if [[ "${INGRESS}" == "nginx" ]]; then
      DISABLE_COMPONENTS="traefik${DISABLE_COMPONENTS:+,${DISABLE_COMPONENTS}}"
      log_info "Ingress: NGINX — Traefik akan dinonaktifkan."
    else
      log_info "Ingress: Traefik (bawaan K3s)."
    fi

    # Bangun flag --disable
    if [[ -n "${DISABLE_COMPONENTS}" ]]; then
      # Konversi koma ke multiple --disable flags
      IFS=',' read -ra DISABLE_ARRAY <<< "${DISABLE_COMPONENTS}"
      for comp in "${DISABLE_ARRAY[@]}"; do
        K3S_INSTALL_ARGS+=" --disable ${comp}"
      done
    fi

    # TLS SAN tambahan
    if [[ -n "${TLS_SAN}" ]]; then
      IFS=',' read -ra SAN_ARRAY <<< "${TLS_SAN}"
      for san in "${SAN_ARRAY[@]}"; do
        K3S_INSTALL_ARGS+=" --tls-san ${san}"
      done
    fi

    # Data directory
    [[ "${DATA_DIR}" != "${DEFAULT_DATA_DIR}" ]] && \
      K3S_INSTALL_ARGS+=" --data-dir ${DATA_DIR}"
  fi

  K3S_INSTALL_ARGS="${K3S_INSTALL_ARGS# }"  # Trim leading space
}

# --- Eksekusi Instalasi K3s ---
run_installation() {
  log_step "Menjalankan instalasi K3s (channel: ${CHANNEL}, role: ${ROLE})..."

  if [[ "${DRY_RUN}" == true ]]; then
    log_warn "[DRY RUN] Perintah yang akan dieksekusi:"
    if [[ "${ROLE}" == "server" ]]; then
      echo "  INSTALL_K3S_CHANNEL=${CHANNEL} curl -sfL ${K3S_INSTALL_URL} | sh -s - ${K3S_INSTALL_ARGS}"
    else
      echo "  INSTALL_K3S_CHANNEL=${CHANNEL} K3S_URL=${SERVER_URL} K3S_TOKEN=${TOKEN} curl -sfL ${K3S_INSTALL_URL} | sh -s - agent"
    fi
    return 0
  fi

  if [[ "${ROLE}" == "server" ]]; then
    INSTALL_K3S_CHANNEL="${CHANNEL}" \
    curl -sfL "${K3S_INSTALL_URL}" | sh -s - ${K3S_INSTALL_ARGS}
  else
    INSTALL_K3S_CHANNEL="${CHANNEL}" \
    K3S_URL="${SERVER_URL}" \
    K3S_TOKEN="${TOKEN}" \
    curl -sfL "${K3S_INSTALL_URL}" | sh -s - agent
  fi
}

# --- Setup kubectl untuk User Saat Ini ---
setup_kubeconfig() {
  if [[ "${ROLE}" != "server" ]] || [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi

  log_step "Mengatur kubeconfig untuk pengguna saat ini..."

  # Tunggu kubeconfig tersedia
  local retries=0
  while [[ ! -f "${KUBECONFIG_FILE}" ]] && [[ "${retries}" -lt 30 ]]; do
    sleep 2
    (( retries++ ))
  done

  if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
    log_warn "Kubeconfig tidak ditemukan di ${KUBECONFIG_FILE} setelah 60 detik."
    return 1
  fi

  # Setup untuk user root (sering dijalankan dengan sudo)
  mkdir -p "${USER_KUBECONFIG%/*}"
  cp "${KUBECONFIG_FILE}" "${USER_KUBECONFIG}"
  chmod 600 "${USER_KUBECONFIG}"
  log_info "Kubeconfig disalin ke ${USER_KUBECONFIG}"

  # Setup untuk user SUDO_USER jika ada
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    local SUDO_HOME
    SUDO_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    local SUDO_KUBECONFIG="${SUDO_HOME}/.kube/config"

    mkdir -p "${SUDO_HOME}/.kube"
    cp "${KUBECONFIG_FILE}" "${SUDO_KUBECONFIG}"
    chown "${SUDO_USER}:${SUDO_USER}" "${SUDO_HOME}/.kube" "${SUDO_KUBECONFIG}"
    chmod 600 "${SUDO_KUBECONFIG}"
    log_info "Kubeconfig disalin ke ${SUDO_KUBECONFIG} (user: ${SUDO_USER})"
  fi

  # Tambahkan KUBECONFIG ke shell profile jika belum ada
  local SHELL_PROFILES=("${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile")
  for profile in "${SHELL_PROFILES[@]}"; do
    if [[ -f "${profile}" ]] && ! grep -q "KUBECONFIG" "${profile}"; then
      echo "export KUBECONFIG=${USER_KUBECONFIG}" >> "${profile}"
      log_info "KUBECONFIG ditambahkan ke ${profile}"
    fi
  done
}

# --- Instalasi Ingress NGINX (opsional) ---
install_nginx_ingress() {
  if [[ "${INGRESS}" != "nginx" ]] || [[ "${ROLE}" != "server" ]] || [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi

  log_step "Menginstal NGINX Ingress Controller..."

  # Tunggu node K3s siap
  local retries=0
  until kubectl get nodes 2>/dev/null | grep -q "Ready" || [[ "${retries}" -ge 30 ]]; do
    log_info "Menunggu node K3s siap... (${retries}/30)"
    sleep 5
    (( retries++ ))
  done

  # Deploy NGINX Ingress via manifest resmi
  kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml"

  log_info "NGINX Ingress Controller berhasil diinstal."
  log_info "Gunakan NodePort service: kubectl get svc -n ingress-nginx"
}

# --- Tampilkan Token Node ---
show_cluster_info() {
  if [[ "${ROLE}" != "server" ]] || [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi

  log_section "Informasi Kluster"

  # Tampilkan token untuk join agent
  if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
    local NODE_TOKEN
    NODE_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    log_info "Token Node (simpan dengan aman!):"
    echo -e "  ${BOLD}${NODE_TOKEN}${NC}"
  fi

  # Tampilkan IP server
  local SERVER_IP
  SERVER_IP=$(hostname -I | awk '{print $1}')
  log_info "Perintah join untuk agent node:"
  echo -e "  ${BOLD}sudo ./install-k3s.sh --role agent --server-url https://${SERVER_IP}:6443 --token <TOKEN_DI_ATAS>${NC}"

  log_section "Verifikasi Kluster"
  log_info "Gunakan perintah berikut untuk memverifikasi instalasi:"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"
  echo "  kubectl cluster-info"
}

# --- Parse Argumen ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)         ROLE="$2";        shift 2 ;;
      --server-url)   SERVER_URL="$2";  shift 2 ;;
      --token)        TOKEN="$2";       shift 2 ;;
      --disable)      DISABLE_COMPONENTS="$2"; shift 2 ;;
      --ingress)      INGRESS="$2";     shift 2 ;;
      --tls-san)      TLS_SAN="$2";     shift 2 ;;
      --data-dir)     DATA_DIR="$2";    shift 2 ;;
      --channel)      CHANNEL="$2";     shift 2 ;;
      --dry-run)      DRY_RUN=true;     shift ;;
      --help|-h)      usage ;;
      *)
        log_error "Argumen tidak dikenal: $1"
        echo "Gunakan --help untuk melihat opsi yang tersedia."
        exit 1
        ;;
    esac
  done

  # Validasi nilai enum
  [[ "${ROLE}"    =~ ^(server|agent)$   ]] || { log_error "Role tidak valid: ${ROLE}"; exit 1; }
  [[ "${INGRESS}" =~ ^(nginx|traefik)$  ]] || { log_error "Ingress tidak valid: ${INGRESS}"; exit 1; }
  [[ "${CHANNEL}" =~ ^(stable|latest)$  ]] || { log_error "Channel tidak valid: ${CHANNEL}"; exit 1; }
}

# --- Main ---
main() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║      K3s Multi-Distro Installer      ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}\n"

  parse_args "$@"
  detect_distro
  check_prerequisites
  configure_kernel
  configure_firewall
  build_install_args
  run_installation
  setup_kubeconfig
  install_nginx_ingress
  show_cluster_info

  log_section "Instalasi Selesai"
  log_info "K3s berhasil diinstal sebagai role: ${BOLD}${ROLE}${NC}"
  [[ "${DRY_RUN}" == true ]] && log_warn "Mode DRY RUN aktif — tidak ada perubahan yang diterapkan."
}

main "$@"
