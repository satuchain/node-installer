#!/bin/bash
# ============================================================
# SatuChain Mainnet — Validator Node Installer
# Version: 2.1.0 — Docker-based deployment
# Usage : curl -fsSL https://raw.githubusercontent.com/satuchain/node-installer/main/install-validator.sh | sudo bash
# Min req: 2 vCPU / 2 GB RAM / 50 GB SSD  |  Rec: 4 vCPU / 4 GB RAM / 100 GB SSD
# ============================================================

set -euo pipefail

# ── Restore terminal stdin (required when running via curl | bash) ─────────────
# When piped through curl, bash stdin is the script pipe — redirect to terminal
# so interactive read commands (passwords, menu selection) work correctly.
if [ -t 0 ]; then
  : # already a terminal
elif [ -e /dev/tty ]; then
  exec < /dev/tty
fi

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
die()   { echo -e "${RED}[✗] ERROR:${NC} $*"; exit 1; }

# ── Constants ────────────────────────────────────────────────
CHAIN_ID=10111945
# Force IPv4 for all API calls — server-side IP whitelist tracks IPv4 only,
# and many residential/VPS IPv6 prefixes rotate so they cannot be whitelisted stably.
CURL_API="curl --ipv4"
API_BASE="https://staking.satuchain.com/api"
RPC_PUBLIC="https://rpc-mainnet.satuchain.com"
STAKING_CONTRACT_ADDR="0xc7062768b9aD389C2b5F4F7aBD3207689A795296"
BOOTNODE=""  # fetched from API during install
INSTALL_DIR="/opt/satuchain-validator"
KEYSTORE_DIR="$INSTALL_DIR/keystore"
CONFIG_DIR="$INSTALL_DIR/config"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
STATE_FILE="$INSTALL_DIR/.state"
MONITOR_SCRIPT="$INSTALL_DIR/monitor.sh"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
BSC_IMAGE="ghcr.io/satuchain/node:1.7.2"
CONTAINER_NAME="satuchain-validator"
INSTALLER_VERSION="2.6.2"
INSTALLER_URL="https://staking.satuchain.com/install-validator.sh"
GITHUB_LATEST_API="https://api.github.com/repos/satuchain/node-installer/releases/latest"

# Minimum requirements — HARD STOP if not met
# Minimum: 2 vCPU / 2 GB RAM / 15 GB Disk
# Recommended: 4 vCPU / 4 GB RAM / 100 GB Disk
REQ_CPU=2
REQ_RAM_GB=2
REQ_DISK_GB=15

# ── State helpers ────────────────────────────────────────────
save_state() { echo "$1=$2" >> "$STATE_FILE"; }
load_state()  { grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
RESUMING=false

# Backend stores bootnode in hostname form (bootnode.satuchain.com) so the public
# dashboard never exposes raw IPs of validator-1. But geth v1.7.2's enode parser
# rejects hostname-form URLs ("bad bootstrap node ... missing IP address"), so
# right before writing config.toml we resolve to literal IP locally.
# Top-level so verify_peering can also call this when fixing existing installs
# without re-running setup_compose_and_start.
write_compose() {
  local mode=${1:-sync}  # "sync" or "validator"
  cat > "$COMPOSE_FILE" <<COMPOSE
services:
  $CONTAINER_NAME:
    image: $BSC_IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    # 60s grace so geth can finish LevelDB compaction on SIGTERM before SIGKILL.
    # Default 10s is too short and causes chaindata corruption on busy nodes.
    stop_grace_period: 60s
    network_mode: host
    # Bypass image's docker-entrypoint.sh which cats /bsc/config/config.toml
    # (we mount our config at /config/, not /bsc/config/). Run geth directly.
    entrypoint: ["geth"]
    volumes:
      - $DATA_DIR:/data
      - $CONFIG_DIR:/config
      - $KEYSTORE_DIR:/data/keystore
      - $LOG_DIR:/logs
    command:
      - --datadir=/data
      - --config=/config/config.toml
      - --networkid=$CHAIN_ID
      - --nat=extip:$PUBLIC_IP
$([ "$mode" = "validator" ] && echo "      - --mine
      - --miner.etherbase=$VALIDATOR_ADDRESS
      - --unlock=$VALIDATOR_ADDRESS
      - --password=/config/password.txt")
      - --bootnodes=$BOOTNODE
      - --verbosity=3
COMPOSE
}

resolve_bootnode_to_ip() {
  local en="$1"
  # Match enode://<pubkey>@<host>:<port>?...
  local re='^(enode://[0-9a-fA-F]+@)([^:?]+)(:[0-9]+.*)$'
  if [[ "$en" =~ $re ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local host="${BASH_REMATCH[2]}"
    local suffix="${BASH_REMATCH[3]}"
    # If host is already an IP (a.b.c.d or [::1] style), keep as-is.
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$host" =~ ^\[ ]]; then
      echo "$en"; return 0
    fi
    local ip
    ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z "$ip" ]]; then
      ip=$(dig +short "$host" 2>/dev/null | head -1)
    fi
    if [[ -z "$ip" ]]; then
      echo "$en"; return 0   # fall back to original; verify_peering will warn
    fi
    echo "${prefix}${ip}${suffix}"
  else
    echo "$en"
  fi
}

# ── Resume detection ─────────────────────────────────────────
# If a previous install exists, offer to skip key re-entry + already-done steps.
detect_resume() {
  [[ ! -f "$STATE_FILE" ]] && return 0
  local prev_addr prev_key
  prev_addr=$(load_state VALIDATOR_ADDRESS)
  prev_key=$(load_state VALIDATOR_KEY)
  [[ -z "$prev_addr" || -z "$prev_key" ]] && return 0

  echo ""
  echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│${NC}  Previous install detected / Install sebelumnya     ${YELLOW}│${NC}"
  echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
  echo -e "  Address : ${CYAN}${prev_addr}${NC}"
  echo -e "  Key     : ${CYAN}${prev_key:0:24}...${NC}"
  echo ""
  echo -e "  ${BOLD}Progress:${NC}"
  [[ -f "$CONFIG_DIR/genesis.json" ]] \
    && echo -e "    ${GREEN}✓${NC} Genesis downloaded" \
    || echo -e "    ${YELLOW}•${NC} Genesis pending"
  if [[ -d "$KEYSTORE_DIR" ]] && [[ -n "$(ls -A "$KEYSTORE_DIR" 2>/dev/null)" ]]; then
    echo -e "    ${GREEN}✓${NC} Keystore exists"
  else
    echo -e "    ${YELLOW}•${NC} Keystore pending"
  fi
  if docker ps --filter "name=satuchain-validator" --filter "status=running" \
       --format "{{.Names}}" 2>/dev/null | grep -q satuchain-validator; then
    echo -e "    ${GREEN}✓${NC} Container running"
  else
    echo -e "    ${YELLOW}•${NC} Container not running"
  fi
  echo ""
  local choice
  echo -en "  Resume install? [Y/n]: "
  read -r choice || choice="Y"
  choice="${choice:-Y}"
  if [[ "$choice" =~ ^[Yy] ]]; then
    VALIDATOR_ADDRESS="$prev_addr"
    VALIDATOR_KEY="$prev_key"
    PUBLIC_IP=$(load_state PUBLIC_IP)
    SERVER_ID=$(load_state SERVER_ID)
    BOOTNODE=$(load_state BOOTNODE)
    VALIDATOR_NAME=$(load_state VALIDATOR_NAME)
    RESUMING=true
    log "Resuming install for $VALIDATOR_ADDRESS"
  else
    info "Starting fresh install — clearing state"
    rm -f "$STATE_FILE"
    RESUMING=false
  fi
}

# ── Language ─────────────────────────────────────────────────
LANG_MODE="en"

select_language() {
  echo ""
  echo -e "  ${BOLD}Select language / Pilih bahasa:${NC}"
  echo "  [1] English  (default)"
  echo "  [2] Bahasa Indonesia"
  echo ""
  read -r -p "  [1/2]: " LC 2>/dev/null || LC="1"
  [[ "$LC" == "2" ]] && LANG_MODE="id" || LANG_MODE="en"
}

t() {
  # t KEY — return translated string
  local key="$1"; shift
  case "$LANG_MODE:$key" in
    id:step_req)       echo "Memeriksa Persyaratan Server" ;;
    id:step_conn)      echo "Memeriksa Koneksi" ;;
    id:step_key)       echo "Validasi Kunci Validator" ;;
    id:step_docker)    echo "Instalasi Docker" ;;
    id:step_genesis)   echo "Unduh Genesis & Konfigurasi" ;;
    id:step_account)   echo "Setup Akun Validator" ;;
    id:step_firewall)  echo "Setup Firewall" ;;
    id:step_compose)   echo "Buat Docker Compose & Mulai Node" ;;
    id:step_monitor)   echo "Setup Monitor Auto-Sinkron" ;;
    id:step_report)    echo "Kirim Info ke Dashboard" ;;
    id:req_cpu)        echo "CPU minimal ${REQ_CPU} core diperlukan (terdeteksi: $*)" ;;
    id:req_ram)        echo "RAM minimal ${REQ_RAM_GB} GB diperlukan (terdeteksi: $* GB)" ;;
    id:req_disk)       echo "Disk bebas minimal ${REQ_DISK_GB} GB diperlukan (tersedia: $* GB)" ;;
    id:req_ok)         echo "Spesifikasi server memenuhi syarat" ;;
    id:req_os)         echo "Hanya Linux x86_64 yang didukung" ;;
    id:conn_ok)        echo "Semua koneksi OK" ;;
    id:conn_no_inet)   echo "Tidak ada koneksi internet" ;;
    id:conn_api_fail)  echo "Staking API tidak merespons" ;;
    id:conn_rpc_fail)  echo "RPC SatuChain tidak merespons" ;;
    id:conn_boot_fail) echo "Bootnode P2P tidak terjangkau — periksa firewall port 30303" ;;
    id:key_prompt_addr)echo "Masukkan alamat wallet validator (0x...):" ;;
    id:key_prompt_key) echo "Masukkan kunci validator (satu-val-...):" ;;
    id:key_invalid_fmt)echo "Format tidak valid" ;;
    id:key_ok)         echo "Kunci valid untuk alamat" ;;
    id:key_rejected)   echo "Kunci ditolak" ;;
    id:key_mismatch)   echo "Alamat tidak cocok dengan kunci ini" ;;
    id:docker_exists)  echo "Docker sudah terinstal" ;;
    id:docker_install) echo "Menginstal Docker..." ;;
    id:docker_ok)      echo "Docker terinstal" ;;
    id:genesis_dl)     echo "Mengunduh genesis dari SatuChain..." ;;
    id:genesis_ok)     echo "Genesis diunduh dan diverifikasi" ;;
    id:genesis_fail)   echo "Gagal mengunduh genesis. Hubungi admin SatuChain." ;;
    id:account_exists) echo "Keystore sudah ada untuk alamat ini" ;;
    id:account_method) echo "Pilih metode import akun validator:" ;;
    id:account_opt1)   echo "  1) Import private key (64 karakter hex)" ;;
    id:account_opt2)   echo "  2) Import file keystore JSON (UTC--...)" ;;
    id:account_note)   echo "  Langkah ini untuk mengizinkan NODE kamu MENANDATANGANI BLOK di SatuChain." ;;
    id:account_note2)  echo "  Kamu perlu memasukkan private key dari wallet validator kamu." ;;
    id:account_note3)  echo "  Private key ini HANYA disimpan terenkripsi di server kamu sendiri," ;;
    id:account_note4)  echo "  dan TIDAK dikirim ke server SatuChain manapun." ;;
    id:account_note5)  echo "  Ini BUKAN Validator Key (satu-val-...) — itu sudah selesai tadi." ;;
    id:account_note6)  echo "  Format: 0x + 64 karakter hex (export dari MetaMask/wallet kamu)" ;;
    id:account_pk)     echo "Masukkan private key wallet validator (0x...):" ;;
    id:account_pw)     echo "Buat password keystore:" ;;
    id:account_pw2)    echo "Konfirmasi password:" ;;
    id:account_pw_err) echo "Password tidak cocok" ;;
    id:account_kf)     echo "Path ke file keystore:" ;;
    id:account_kf_err) echo "File tidak ditemukan" ;;
    id:account_kpw)    echo "Password keystore:" ;;
    id:account_exist_pw) echo "Password keystore yang sudah ada:" ;;
    id:account_ok)     echo "Akun siap" ;;
    id:fw_ok)          echo "Firewall: SSH(22) + P2P(30303) terbuka, semua lainnya ditolak" ;;
    id:fw_skip)        echo "ufw tidak tersedia, lewati konfigurasi firewall" ;;
    id:compose_pull)           echo "Menarik image Docker BSC..." ;;
    id:compose_start)          echo "Memulai node (mode sinkron)..." ;;
    id:compose_ok)             echo "Node berjalan dalam mode sinkron!" ;;
    id:compose_fail)           echo "Node gagal start. Cek: docker logs $CONTAINER_NAME" ;;
    id:sync_mode_start)        echo "Node sedang sinkron blockchain..." ;;
    id:waiting_activation)     echo "Menunggu persetujuan aktivasi dari admin dashboard... (cek setiap 30 detik)" ;;
    id:still_waiting)          echo "Masih menunggu persetujuan admin" ;;
    id:activation_approved)    echo "Persetujuan diterima! Mengaktifkan mode validator..." ;;
    id:starting_validator_mode)echo "Memulai ulang node dalam mode validator (--mine)..." ;;
    id:validator_mode_ok)      echo "Node aktif sebagai validator!" ;;
    id:monitor_ok)             echo "Monitor aktif — sinkron ke dashboard setiap 5 menit" ;;
    id:report_ok)              echo "Info awal dikirim ke dashboard" ;;
    id:summary_title)          echo "Instalasi Berhasil!" ;;
    id:summary_logs)           echo "Pantau log:" ;;
    id:summary_view)           echo "Pantau di dashboard:" ;;
    id:summary_next)           echo "Langkah selanjutnya (otomatis):" ;;
    id:summary_s1)             echo "Node sinkron dengan SatuChain" ;;
    id:summary_s2)             echo "Monitor kirim status ke dashboard tiap 5 menit" ;;
    id:summary_s3)             echo "Setelah admin approve, node otomatis aktif sebagai validator" ;;
    # English (default)
    en:step_req)       echo "Checking Server Requirements" ;;
    en:step_conn)      echo "Checking Connectivity" ;;
    en:step_key)       echo "Validating Validator Key" ;;
    en:step_docker)    echo "Installing Docker" ;;
    en:step_genesis)   echo "Downloading Genesis & Config" ;;
    en:step_account)   echo "Setting Up Validator Account" ;;
    en:step_firewall)  echo "Configuring Firewall" ;;
    en:step_compose)   echo "Creating Docker Compose & Starting Node" ;;
    en:step_monitor)   echo "Setting Up Auto-Sync Monitor" ;;
    en:step_report)    echo "Sending Initial Info to Dashboard" ;;
    en:req_cpu)        echo "Minimum ${REQ_CPU} CPU cores required (detected: $*)" ;;
    en:req_ram)        echo "Minimum ${REQ_RAM_GB} GB RAM required (detected: $* GB)" ;;
    en:req_disk)       echo "Minimum ${REQ_DISK_GB} GB free disk required (available: $* GB)" ;;
    en:req_ok)         echo "Server meets all requirements" ;;
    en:req_os)         echo "Only Linux x86_64 is supported" ;;
    en:conn_ok)        echo "All connections OK" ;;
    en:conn_no_inet)   echo "No internet connection" ;;
    en:conn_api_fail)  echo "Staking API not responding" ;;
    en:conn_rpc_fail)  echo "SatuChain RPC not responding" ;;
    en:conn_boot_fail) echo "Bootnode P2P unreachable — check firewall port 30303" ;;
    en:key_prompt_addr)echo "Enter validator wallet address (0x...):" ;;
    en:key_prompt_key) echo "Enter validator key (satu-val-...):" ;;
    en:key_invalid_fmt)echo "Invalid format" ;;
    en:key_ok)         echo "Key valid for address" ;;
    en:key_rejected)   echo "Key rejected" ;;
    en:key_mismatch)   echo "Address does not match this key" ;;
    en:docker_exists)  echo "Docker is already installed" ;;
    en:docker_install) echo "Installing Docker..." ;;
    en:docker_ok)      echo "Docker installed" ;;
    en:genesis_dl)     echo "Downloading genesis from SatuChain..." ;;
    en:genesis_ok)     echo "Genesis downloaded and verified" ;;
    en:genesis_fail)   echo "Failed to download genesis. Contact SatuChain admin." ;;
    en:account_exists) echo "Keystore already exists for this address" ;;
    en:account_method) echo "Select validator account import method:" ;;
    en:account_opt1)   echo "  1) Import private key (64-char hex)" ;;
    en:account_opt2)   echo "  2) Import keystore JSON file (UTC--...)" ;;
    en:account_note)   echo "  This step allows your NODE to SIGN BLOCKS on SatuChain." ;;
    en:account_note2)  echo "  You need to enter the private key of your validator wallet." ;;
    en:account_note3)  echo "  This key is stored ENCRYPTED on YOUR server only —" ;;
    en:account_note4)  echo "  it is NEVER sent to SatuChain servers." ;;
    en:account_note5)  echo "  This is NOT the Validator Key (satu-val-...) from the previous step." ;;
    en:account_note6)  echo "  Format: 0x + 64 hex characters (export from MetaMask/your wallet)" ;;
    en:account_pk)     echo "Enter validator wallet private key (0x...):" ;;
    en:account_pw)     echo "Create keystore password:" ;;
    en:account_pw2)    echo "Confirm password:" ;;
    en:account_pw_err) echo "Passwords do not match" ;;
    en:account_kf)     echo "Path to keystore file:" ;;
    en:account_kf_err) echo "File not found:" ;;
    en:account_kpw)    echo "Keystore password:" ;;
    en:account_exist_pw) echo "Enter existing keystore password:" ;;
    en:account_ok)     echo "Account ready" ;;
    en:fw_ok)          echo "Firewall: SSH(22) + P2P(30303) open, all others denied" ;;
    en:fw_skip)        echo "ufw not available, skipping firewall setup" ;;
    en:compose_pull)           echo "Pulling BSC Docker image..." ;;
    en:compose_start)          echo "Starting node (sync mode)..." ;;
    en:compose_ok)             echo "Node running in sync mode!" ;;
    en:compose_fail)           echo "Node failed to start. Check: docker logs $CONTAINER_NAME" ;;
    en:sync_mode_start)        echo "Node is syncing the blockchain..." ;;
    en:waiting_activation)     echo "Waiting for activation approval from admin dashboard... (checking every 30s)" ;;
    en:still_waiting)          echo "Still waiting for admin approval" ;;
    en:activation_approved)    echo "Approval received! Activating validator mode..." ;;
    en:starting_validator_mode)echo "Restarting node in validator mode (--mine)..." ;;
    en:validator_mode_ok)      echo "Node is now active as validator!" ;;
    en:monitor_ok)             echo "Monitor active — syncing to dashboard every 5 minutes" ;;
    en:report_ok)              echo "Initial info sent to dashboard" ;;
    en:summary_title)          echo "Installation Successful!" ;;
    en:summary_logs)           echo "Monitor logs:" ;;
    en:summary_view)   echo "View on dashboard:" ;;
    en:summary_next)   echo "Next steps (automatic):" ;;
    en:summary_s1)     echo "Node syncing with SatuChain" ;;
    en:summary_s2)     echo "Monitor sends status to dashboard every 5 minutes" ;;
    en:summary_s3)     echo "When synced, admin gets notified to approve your validator" ;;
    *)                 echo "$key $*" ;;
  esac
}

# ── Report install progress to dashboard ─────────────────────
# Called throughout installation so portal shows real-time progress
report_status() {
  local step="$1"
  local status="$2"   # started | done | failed
  local msg="${3:-}"
  # VALIDATOR_ADDRESS may not be set yet at early steps — skip silently
  [[ -z "${VALIDATOR_ADDRESS:-}" ]] && return 0
  $CURL_API -s --max-time 5 -X POST "$API_BASE/node-install-log" \
    -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"step\":\"$step\",\"status\":\"$status\",\"msg\":\"$msg\"}" \
    >/dev/null 2>&1 || true
}

# ── Banner ───────────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}"
  echo "  ███████╗ █████╗ ████████╗██╗   ██╗ ██████╗██╗  ██╗ █████╗ ██╗███╗   ██╗"
  echo "  ██╔════╝██╔══██╗╚══██╔══╝██║   ██║██╔════╝██║  ██║██╔══██╗██║████╗  ██║"
  echo "  ███████╗███████║   ██║   ██║   ██║██║     ███████║███████║██║██╔██╗ ██║"
  echo "  ╚════██║██╔══██║   ██║   ██║   ██║██║     ██╔══██║██╔══██║██║██║╚██╗██║"
  echo "  ███████║██║  ██║   ██║   ╚██████╔╝╚██████╗██║  ██║██║  ██║██║██║ ╚████║"
  echo "  ╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝"
  echo -e "${NC}"
  echo -e "${BOLD}  SatuChain Mainnet — Validator Node Installer v${INSTALLER_VERSION}${NC}"
  echo -e "  Chain ID: ${CYAN}$CHAIN_ID${NC}  •  APoS Consensus  •  Docker-based"
  echo ""
}

# ════════════════════════════════════════════════════════════
# STEP 1 — Requirements (HARD STOP if not met)
# ════════════════════════════════════════════════════════════
check_requirements() {
  step "$(t step_req)"

  # OS & arch
  [[ "$(uname -s)" == "Linux" ]]  || die "$(t req_os)"
  [[ "$(uname -m)" == "x86_64" ]] || die "$(t req_os)"
  [[ $EUID -eq 0 ]]               || die "Must run as root: sudo bash install-validator.sh"

  # CPU
  CPU=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  if [[ $CPU -lt $REQ_CPU ]]; then
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  ✗  CPU CHECK FAILED                                 ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  Detected : ${RED}${CPU} vCPU${NC}"
    echo -e "  Required : ${GREEN}${REQ_CPU} vCPU minimum${NC}"
    echo -e "  Recommended : ${GREEN}4 vCPU${NC} for stable long-term operation"
    echo ""
    echo -e "  ${YELLOW}→ Solution: Upgrade your VPS to at least 2 vCPU (recommended 4 vCPU)${NC}"
    echo -e "  ${YELLOW}  Examples: Hetzner CPX21 (3vCPU/4GB ~€6/mo)${NC}"
    echo -e "  ${YELLOW}            Contabo VPS S (4vCPU/8GB ~\$8.49/mo)${NC}"
    echo -e "  ${YELLOW}            IDCloudHost / BizNet Gio (4vCPU/4GB, regional ID)${NC}"
    echo ""
    die "CPU insufficient: ${CPU} vCPU < ${REQ_CPU} vCPU required"
  fi

  # RAM — check physical + swap combined
  RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  RAM_GB=$(( RAM_KB / 1024 / 1024 ))
  SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_GB=$(( SWAP_KB / 1024 / 1024 ))
  TOTAL_MEM_GB=$(( RAM_GB + SWAP_GB ))

  if [[ $RAM_GB -lt $REQ_RAM_GB ]]; then
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  ✗  RAM CHECK FAILED                                 ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  Detected RAM  : ${RED}${RAM_GB} GB${NC} (need ${REQ_RAM_GB} GB minimum)"
    echo -e "  Current Swap  : ${SWAP_GB} GB"
    echo -e "  Total Memory  : ${TOTAL_MEM_GB} GB"
    echo ""
    if [[ $TOTAL_MEM_GB -ge $REQ_RAM_GB ]]; then
      echo -e "  ${GREEN}✓ Swap already covers minimum — continuing with warning${NC}"
    else
      # Offer to auto-create swap
      echo -e "  ${YELLOW}→ Your server has only ${RAM_GB} GB RAM.${NC}"
      echo -e "  ${YELLOW}  A swap file can compensate. Auto-create 2 GB swap?${NC}"
      echo ""
      read -r -p "  Create 2 GB swap file automatically? [Y/n]: " MKSWAP 2>/dev/null || MKSWAP="Y"
      if [[ "${MKSWAP,,}" != "n" ]]; then
        echo ""
        info "Creating 2 GB swap file at /swapfile..."
        if [[ -f /swapfile ]]; then
          info "Swap file already exists — reusing."
          swapon /swapfile 2>/dev/null || true
        else
          fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
          chmod 600 /swapfile
          mkswap /swapfile -q
          swapon /swapfile
          # Persist across reboots
          grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        SWAP_GB=$(( SWAP_KB / 1024 / 1024 ))
        TOTAL_MEM_GB=$(( RAM_GB + SWAP_GB ))
        log "Swap created: ${SWAP_GB} GB — Total effective memory: ${TOTAL_MEM_GB} GB"
        if [[ $TOTAL_MEM_GB -lt $REQ_RAM_GB ]]; then
          die "Not enough memory even with swap (${TOTAL_MEM_GB} GB total). Please upgrade your server."
        fi
      else
        echo ""
        echo -e "  ${YELLOW}→ To fix manually, run:${NC}"
        echo -e "     fallocate -l 2G /swapfile"
        echo -e "     chmod 600 /swapfile"
        echo -e "     mkswap /swapfile"
        echo -e "     swapon /swapfile"
        echo -e "     echo '/swapfile none swap sw 0 0' >> /etc/fstab"
        echo ""
        echo -e "  ${YELLOW}  Then re-run this installer.${NC}"
        die "RAM insufficient: ${RAM_GB} GB < ${REQ_RAM_GB} GB required"
      fi
    fi
    warn "Running on ${RAM_GB} GB RAM + ${SWAP_GB} GB swap. Monitor memory: free -h"
  fi

  # Disk (check /opt or /)
  DISK_FREE=$(df -BG "${INSTALL_DIR%/*}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' \
              || df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
  if [[ ${DISK_FREE:-0} -lt $REQ_DISK_GB ]]; then
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  ✗  DISK CHECK FAILED                                ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  Free disk  : ${RED}${DISK_FREE} GB${NC} (need ${REQ_DISK_GB} GB minimum)"
    echo -e "  Recommended: ${GREEN}100 GB SSD${NC} — chain data grows ~1-2 GB/month"
    echo ""
    echo -e "  ${YELLOW}→ Free up disk space or upgrade to a larger volume.${NC}"
    echo -e "  ${YELLOW}  Check usage: du -sh /* 2>/dev/null | sort -rh | head${NC}"
    echo ""
    die "Disk insufficient: ${DISK_FREE} GB free < ${REQ_DISK_GB} GB required"
  fi

  log "$(t req_ok) — CPU: ${CPU}c | RAM: ${RAM_GB}GB + ${SWAP_GB}GB swap | Disk free: ${DISK_FREE}GB"

  # Warn if below recommended (not a hard stop)
  local warn_shown=0
  if [[ $CPU -lt 4 ]]; then
    warn "CPU ${CPU} vCPU — recommended 4 vCPU. Node will work but may lag under heavy load."
    warn_shown=1
  fi
  if [[ $RAM_GB -lt 4 ]]; then
    warn "RAM ${RAM_GB} GB — recommended 4 GB for long-term stability."
    warn_shown=1
  fi
  if [[ ${DISK_FREE:-0} -lt 100 ]]; then
    warn "Disk ${DISK_FREE} GB free — recommended 100 GB. Monitor with: df -h"
    warn_shown=1
  fi
  if [[ $warn_shown -eq 1 ]]; then
    echo ""
    echo -e "  ${YELLOW}▸ Minimum met. Best performance: 4 vCPU / 4 GB RAM / 100 GB SSD${NC}"
    echo -e "  ${YELLOW}  Recommended VPS: Hetzner CPX21 €6/mo · Contabo VPS S \$8.49/mo · IDCloudHost ~Rp 200K/mo${NC}"
    echo ""
  fi
}

# ════════════════════════════════════════════════════════════
# STEP 2 — Connectivity (warn + ask, not hard stop)
# ════════════════════════════════════════════════════════════
check_connectivity() {
  step "$(t step_conn)"
  local FAILED=0

  # Internet
  curl -s --max-time 8 https://google.com -o /dev/null 2>/dev/null \
    && log "Internet OK" \
    || { warn "$(t conn_no_inet)"; FAILED=$(( FAILED + 1 )); }

  # Staking API
  $CURL_API -s --max-time 10 "$API_BASE/health" 2>/dev/null | python3 -c \
    "import json,sys; assert json.load(sys.stdin).get('ok')" 2>/dev/null \
    && log "Staking API OK" \
    || { warn "$(t conn_api_fail): $API_BASE/health"; FAILED=$(( FAILED + 1 )); }

  # Public RPC
  BLOCK=$(curl -s --max-time 10 -X POST "$RPC_PUBLIC" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "")
  [[ -n "$BLOCK" ]] \
    && log "RPC OK — Block: $BLOCK" \
    || { warn "$(t conn_rpc_fail): $RPC_PUBLIC"; FAILED=$(( FAILED + 1 )); }

  # P2P bootnode
  timeout 8 bash -c "echo >/dev/tcp/bootnode.satuchain.com/30303" 2>/dev/null \
    && log "Bootnode P2P OK" \
    || { warn "$(t conn_boot_fail)"; FAILED=$(( FAILED + 1 )); }

  if [[ $FAILED -gt 0 ]]; then
    echo ""
    warn "$FAILED connection issue(s) detected."
    read -r -p "  Continue anyway? [y/N]: " CONT 2>/dev/null || CONT="n"
    [[ "$CONT" =~ ^[yY]$ ]] || die "Cancelled. Fix connectivity and re-run."
  else
    log "$(t conn_ok)"
  fi
}

# ════════════════════════════════════════════════════════════
# STEP 3 — Requirements check + key validation (SECURITY GATE)
# ════════════════════════════════════════════════════════════
validate_key() {
  step "$(t step_key)"

  # Resume short-circuit — skip prompts but still refresh BOOTNODE from server
  if [[ "$RESUMING" == "true" ]] && [[ -n "$VALIDATOR_ADDRESS" ]] && [[ -n "$VALIDATOR_KEY" ]]; then
    info "Resuming — refreshing bootnode for $VALIDATOR_ADDRESS"
    local resp fresh_boot
    resp=$($CURL_API -s --max-time 10 -X POST "$API_BASE/validate-key" \
      -H "Content-Type: application/json" \
      -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\"}" 2>/dev/null || echo "")
    fresh_boot=$(echo "$resp" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('bootnode',''))" 2>/dev/null || echo "")
    if [[ -n "$fresh_boot" ]]; then
      fresh_boot=$(resolve_bootnode_to_ip "$fresh_boot")
      if [[ "$fresh_boot" != "$BOOTNODE" ]]; then
        info "BOOTNODE updated from server"
        BOOTNODE="$fresh_boot"
        save_state "BOOTNODE" "$BOOTNODE"
      fi
    fi
    return 0
  fi

  echo -e "${BOLD}$(t key_prompt_addr)${NC}"
  read -r VALIDATOR_ADDRESS 2>/dev/null || die "No input"

  [[ "$VALIDATOR_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || die "$(t key_invalid_fmt): address must be 0x + 40 hex chars"

  # ── Check requirements via API (HARD STOP if not met) ──────
  info "Checking validator requirements on SatuChain..."
  REQ_RESPONSE=$(curl -s --max-time 15 \
    "$API_BASE/validator-requirements/$VALIDATOR_ADDRESS" 2>/dev/null) \
    || die "Cannot reach SatuChain API to verify requirements"

  [[ -z "$REQ_RESPONSE" ]] && die "Cannot reach SatuChain API"

  # Parse fields
  CAN_INSTALL=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('canInstall',False))" 2>/dev/null || echo "False")
  IS_EXEMPT=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('exempt',False))" 2>/dev/null || echo "False")
  STU_MET=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['stu']['met'])" 2>/dev/null || echo "False")
  STU_STAKED=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['stu']['staked'])" 2>/dev/null || echo "0")
  ADMIN_MET=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['adminApproved']['met'])" 2>/dev/null || echo "False")

  # Get validator name from requirements response
  VALIDATOR_NAME=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

  # Display status table
  echo ""
  echo -e "  ${BOLD}Validator Requirements:${NC}"
  echo -e "  ────────────────────────────────────────────────"
  if [[ -n "$VALIDATOR_NAME" ]]; then
    echo -e "  Name   : ${CYAN}${VALIDATOR_NAME}${NC}"
  fi
  echo -e "  Address: ${CYAN}${VALIDATOR_ADDRESS}${NC}"
  echo ""

  if [[ "$IS_EXEMPT" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} STU self-stake            (exempt — admin override)"
  elif [[ "$STU_MET" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} 2,000,000 STU self-stake (staked: ${STU_STAKED} STU — auto-detected on-chain)"
  else
    echo -e "  ${RED}[✗]${NC} 2,000,000 STU self-stake (staked: ${STU_STAKED} STU — insufficient, need 2,000,000)"
  fi

  if [[ "$ADMIN_MET" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} Admin approval           (key issued — ready)"
  else
    echo -e "  ${RED}[✗]${NC} Admin approval           (waiting — admin must issue your key)"
  fi
  echo -e "  ────────────────────────────────────────────────"
  echo ""

  [[ "$CAN_INSTALL" == "True" ]] \
    || die "Requirements not met. Complete the requirements above, then re-run this installer."

  log "All requirements verified — proceeding with installation"

  echo -e "${BOLD}$(t key_prompt_key)${NC}"
  read -r -s VALIDATOR_KEY 2>/dev/null || die "No input"
  echo ""

  [[ "$VALIDATOR_KEY" =~ ^satu-val-[0-9a-f]{40}$ ]] \
    || die "$(t key_invalid_fmt): key must start with satu-val-"

  SERVER_ID=$(cat /etc/machine-id 2>/dev/null || hostname | md5sum | cut -c1-16)
  PUBLIC_IP=$(curl -4 -sf https://api.ipify.org --max-time 10 2>/dev/null \
           || curl -4 -sf https://ifconfig.me --max-time 10 2>/dev/null \
           || echo "unknown")

  info "Validating with SatuChain server..."
  RESPONSE=$($CURL_API -s --max-time 15 -X POST "$API_BASE/validate-key" \
    -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"serverId\":\"$SERVER_ID\",\"serverIp\":\"$PUBLIC_IP\"}" \
    2>/dev/null) || die "Cannot reach SatuChain API"

  [[ -z "$RESPONSE" ]] && die "Cannot reach SatuChain API"

  VALID=$(echo "$RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('valid',False))" 2>/dev/null || echo "False")
  [[ "$VALID" == "True" ]] || {
    ERR=$(echo "$RESPONSE" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('error','invalid key'))" 2>/dev/null || echo "invalid key")
    die "$(t key_rejected): $ERR"
  }

  # Anti-spoofing: verify address from server
  SERVER_ADDR=$(echo "$RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
  ADDR_LOWER=$(echo "$VALIDATOR_ADDRESS" | tr '[:upper:]' '[:lower:]')
  [[ "$SERVER_ADDR" == "$ADDR_LOWER" ]] || die "$(t key_mismatch)"

  log "$(t key_ok): $VALIDATOR_ADDRESS"

  # Fetch bootnode from server response (never hardcoded). Server returns the
  # public hostname-form enode; resolve locally so config.toml ends up with IP.
  BOOTNODE=$(echo "$RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('bootnode',''))" 2>/dev/null || echo "")
  [[ -z "$BOOTNODE" ]] && die "Cannot retrieve network bootnode from server"
  BOOTNODE=$(resolve_bootnode_to_ip "$BOOTNODE")

  # Save state — overwrite cleanly with this run's credentials
  mkdir -p "$INSTALL_DIR"
  : > "$STATE_FILE"
  save_state "VALIDATOR_ADDRESS" "$VALIDATOR_ADDRESS"
  save_state "VALIDATOR_KEY"     "$VALIDATOR_KEY"
  save_state "VALIDATOR_NAME"    "$VALIDATOR_NAME"
  save_state "SERVER_ID"         "$SERVER_ID"
  save_state "PUBLIC_IP"         "$PUBLIC_IP"
  save_state "VALIDATED_AT"      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_state "BOOTNODE"          "$BOOTNODE"
  chmod 600 "$STATE_FILE"
}

# ════════════════════════════════════════════════════════════
# STEP 4 — Install Docker (auto, no interaction needed)
# ════════════════════════════════════════════════════════════
install_docker() {
  step "$(t step_docker)"

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    log "$(t docker_exists): $(docker --version)"
    report_status "docker" "done" "$(docker --version)"
    return
  fi

  info "$(t docker_install)"
  report_status "docker" "started" "Installing Docker..."

  # Install via official Docker script (supports Ubuntu, Debian, CentOS, Fedora)
  if ! curl -fsSL https://get.docker.com | sh; then
    report_status "docker" "failed" "Docker installation failed. Run: apt-get install -y docker.io"
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
    echo -e "${RED}  Docker installation failed.${NC}"
    echo -e "${RED}  Try manually:${NC}"
    echo -e "${RED}  apt-get update && apt-get install -y docker.io${NC}"
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
    die "Docker installation failed"
  fi

  # Enable + start Docker service
  systemctl enable docker --now 2>/dev/null || service docker start 2>/dev/null || true

  # Wait for Docker to be ready
  local retries=10
  while ! docker info &>/dev/null 2>&1; do
    sleep 2
    retries=$(( retries - 1 ))
    [[ $retries -le 0 ]] && { report_status "docker" "failed" "Docker not responding after install"; die "Docker started but not responding"; }
  done

  log "$(t docker_ok): $(docker --version)"
  report_status "docker" "done" "$(docker --version)"
}

# ════════════════════════════════════════════════════════════
# STEP 5 — Download genesis & write config
# ════════════════════════════════════════════════════════════
setup_genesis() {
  step "$(t step_genesis)"
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$KEYSTORE_DIR" "$LOG_DIR"

  info "$(t genesis_dl)"
  report_status "genesis" "started" "Downloading genesis block..."
  $CURL_API -sfL "$API_BASE/genesis" --max-time 30 -o "$CONFIG_DIR/genesis.json" 2>/dev/null \
    || { report_status "genesis" "failed" "Failed to download genesis from $API_BASE"; die "$(t genesis_fail)"; }

  # Verify chain ID
  GENESIS_CID=$(python3 -c "import json; d=json.load(open('$CONFIG_DIR/genesis.json')); print(d.get('config',{}).get('chainId',0))" 2>/dev/null || echo "0")
  [[ "$GENESIS_CID" == "$CHAIN_ID" ]] \
    || die "Genesis chainId mismatch (expected $CHAIN_ID, got $GENESIS_CID)"

  # Verify genesis checksum against API
  LOCAL_SHA=$(sha256sum "$CONFIG_DIR/genesis.json" | awk '{print $1}')
  REMOTE_SHA=$(curl -sf "$API_BASE/genesis-checksum" --max-time 10 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha256',''))" 2>/dev/null || echo "")
  if [[ -n "$REMOTE_SHA" && "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    rm -f "$CONFIG_DIR/genesis.json"
    die "Genesis checksum mismatch! File may be tampered. Contact SatuChain admin."
  fi

  log "$(t genesis_ok) (chainId: $CHAIN_ID)"
  report_status "genesis" "done" "Genesis verified (chainId: $CHAIN_ID)"

  # config.toml for the Docker container
  cat > "$CONFIG_DIR/config.toml" <<TOML
[Eth]
NetworkId = $CHAIN_ID
SyncMode = "snap"

[Eth.TxPool]
PriceLimit = 1000000000
PriceBump = 10
AccountSlots = 512
GlobalSlots = 10000
AccountQueue = 256
GlobalQueue = 5000

[Node]
DataDir = "/data"
InsecureUnlockAllowed = true
NoUSB = true
IPCPath = "geth.ipc"
HTTPHost = "127.0.0.1"
HTTPPort = 8545
HTTPModules = ["eth", "net", "web3"]
HTTPVirtualHosts = ["localhost"]

[Node.P2P]
MaxPeers = 50
ListenAddr = ":30303"
BootstrapNodes = ["$BOOTNODE"]

[Node.HTTPTimeouts]
ReadTimeout = 30000000000
WriteTimeout = 30000000000
IdleTimeout = 120000000000
TOML
}

# ════════════════════════════════════════════════════════════
# STEP 6 — Setup validator keystore
# ════════════════════════════════════════════════════════════
setup_account() {
  step "$(t step_account)"
  report_status "keystore" "started" "Setting up validator keystore..."

  # Default — overridden below when picking new password method.
  # Required so set -u doesn't crash on existing-keystore + summary paths.
  KEYSTORE_PASSWORD_AUTO=false

  ADDR_LOWER=$(echo "$VALIDATOR_ADDRESS" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')
  EXISTING=$(find "$KEYSTORE_DIR" -iname "*${ADDR_LOWER}*" 2>/dev/null | head -1 || true)

  if [[ -n "$EXISTING" ]]; then
    info "$(t account_exists)"
    # If we have an auto-saved password from previous run, reuse it silently
    local saved_pw saved_auto
    saved_auto=$(load_state KEYSTORE_PASSWORD_AUTO)
    saved_pw=$(load_state KEYSTORE_PASSWORD)
    if [[ "$saved_auto" == "true" ]] && [[ -n "$saved_pw" ]]; then
      KEYSTORE_PASSWORD="$saved_pw"
      KEYSTORE_PASSWORD_AUTO=true
      log "Using stored auto-password (from previous install)"
    else
      echo -e "${BOLD}$(t account_exist_pw)${NC}"
      read -r -s KEYSTORE_PASSWORD 2>/dev/null; echo ""
      KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD%$'\r'}"
    fi
  else
    # Explanation box
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${BOLD}🔑 Setup Node Signing Key${NC}                                        ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                                                                 ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  $(t account_note)    ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  $(t account_note2)           ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                                                                 ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  $(t account_note3)     ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  $(t account_note4)                         ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                                                                 ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}$(t account_note5)${NC}  ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  $(t account_note6)     ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "$(t account_method)"
    echo -e "${BOLD}$(t account_opt1)${NC}"
    echo -e "${BOLD}$(t account_opt2)${NC}"

    while true; do
      read -r -p "  [1/2]: " OPT 2>/dev/null || OPT="1"
      [[ "$OPT" == "1" || "$OPT" == "2" ]] && break
      echo -e "${RED}  ✗ Masukkan angka 1 atau 2 (Enter 1 or 2)${NC}"
    done

    case $OPT in
      1)
        echo -e "${BOLD}$(t account_pk)${NC}"
        while true; do
          read -r -s PRIVKEY; echo ""
          # Strip 0x prefix (accept with or without)
          PRIVKEY="${PRIVKEY#0x}"
          PRIVKEY="${PRIVKEY#0X}"
          if [[ ${#PRIVKEY} -eq 64 ]] && [[ "$PRIVKEY" =~ ^[0-9a-fA-F]+$ ]]; then
            break
          fi
          echo -e "${RED}  ✗ Format salah / Invalid format.${NC}"
          echo -e "${RED}    Harus: 0x + 64 karakter hex (total 66 karakter)${NC}"
          echo -e "${RED}    Must be: 0x + 64 hex characters (66 chars total)${NC}"
          echo -e "${BOLD}$(t account_pk)${NC}"
        done

        # Password method — auto-generate (default, recommended) or manual
        echo ""
        echo -e "${BOLD}Password keystore:${NC}"
        echo -e "  ${GREEN}[1]${NC} Auto-generate (recommended — disimpan di /opt/satuchain-validator/.state)"
        echo -e "  ${BOLD}[2]${NC} Set sendiri / Set manually"
        echo -en "  [1/2]: "
        read -r PW_METHOD || PW_METHOD="1"
        PW_METHOD="${PW_METHOD:-1}"

        if [[ "$PW_METHOD" == "1" ]]; then
          # 32-char random hex password — openssl avoids tr|head SIGPIPE under pipefail
          KEYSTORE_PASSWORD=$(openssl rand -hex 16 2>/dev/null \
            || { dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'; })
          KEYSTORE_PASSWORD_AUTO=true
          echo -e "  ${GREEN}✓${NC} Auto-generated 32-char password"
        else
          KEYSTORE_PASSWORD_AUTO=false
          while true; do
            echo -e "${BOLD}$(t account_pw)${NC}"
            read -r -s KEYSTORE_PASSWORD; echo ""
            KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD%$'\r'}"
            if [[ -z "$KEYSTORE_PASSWORD" ]]; then
              echo -e "${RED}  ✗ Password kosong — coba lagi / empty, try again${NC}"
              continue
            fi
            if [[ ${#KEYSTORE_PASSWORD} -lt 8 ]]; then
              echo -e "${YELLOW}  ! Password minimal 8 karakter / minimum 8 chars${NC}"
              continue
            fi
            echo -e "${BOLD}$(t account_pw2)${NC}"
            read -r -s KP2; echo ""
            KP2="${KP2%$'\r'}"
            if [[ "$KEYSTORE_PASSWORD" == "$KP2" ]]; then
              break
            fi
            echo -e "${RED}  ✗ $(t account_pw_err) (len: ${#KEYSTORE_PASSWORD} vs ${#KP2}) — coba lagi / try again${NC}"
            echo -e "${YELLOW}    Tip: jangan copy-paste, ketik manual. Cek caps lock + layout keyboard.${NC}"
            echo ""
          done
        fi

        # Use Docker to import — secure tmpdir (mode 700, not world-readable /tmp)
        SECURE_TMP=$(mktemp -d)
        chmod 700 "$SECURE_TMP"
        echo "$PRIVKEY" > "$SECURE_TMP/.pk"
        echo "$KEYSTORE_PASSWORD" > "$SECURE_TMP/.pw"
        # 644 so container UID 1000 can read via bind-mount.
        # Dir is 700 on host so others still can't traverse here.
        chmod 644 "$SECURE_TMP/.pk" "$SECURE_TMP/.pw"

        # Pre-pull image so user sees progress (first run is ~100MB).
        # Without this, the `docker run` below pulls silently and a slow/failed
        # pull looks like the installer hangs or exits silently under set -e.
        info "Pulling validator node image (~100MB, first time only)..."
        set +e
        docker pull "$BSC_IMAGE"
        PULL_RC=$?
        set -e
        if [[ $PULL_RC -ne 0 ]]; then
          report_status "keystore" "failed" "docker pull $BSC_IMAGE failed (exit $PULL_RC)"
          die "Failed to pull $BSC_IMAGE. Check internet + 'docker pull $BSC_IMAGE' manually."
        fi

        info "Importing private key into keystore..."
        # Override entrypoint: image's docker-entrypoint.sh reads /bsc/config/config.toml
        # which doesn't exist yet during install. Call geth directly to skip that.
        # --user root: container's default UID 1000 can't read /tmp/pk.txt (root-owned)
        # or write to /keystore (root-owned on host). Runtime container runs as 1000 normally.
        set +e
        docker run --rm \
          --entrypoint geth \
          --user root \
          -v "$KEYSTORE_DIR:/keystore" \
          -v "$SECURE_TMP/.pk:/tmp/pk.txt:ro" \
          -v "$SECURE_TMP/.pw:/tmp/pw.txt:ro" \
          "$BSC_IMAGE" \
          account import --keystore /keystore --password /tmp/pw.txt /tmp/pk.txt
        IMPORT_RC=$?
        set -e

        # If running as root in container, the created UTC-* file will be owned by root.
        # Runtime container is UID 1000, so fix ownership.
        chown -R 1000:1000 "$KEYSTORE_DIR" 2>/dev/null || true
        if [[ $IMPORT_RC -ne 0 ]]; then
          report_status "keystore" "failed" "Account import failed (exit $IMPORT_RC)"
          die "Failed to import private key into keystore. Check output above."
        fi
        # Wipe and remove secure temp
        shred -u "$SECURE_TMP/.pk" "$SECURE_TMP/.pw" 2>/dev/null || rm -f "$SECURE_TMP/.pk" "$SECURE_TMP/.pw"
        rmdir "$SECURE_TMP"
        unset PRIVKEY
        log "Private key imported"
        ;;
      2)
        echo -e "${BOLD}$(t account_kf)${NC}"
        read -r KF 2>/dev/null || die "No input"
        [[ -f "$KF" ]] || die "$(t account_kf_err) $KF"
        cp "$KF" "$KEYSTORE_DIR/"
        echo -e "${BOLD}$(t account_kpw)${NC}"
        read -r -s KEYSTORE_PASSWORD; echo ""
        log "Keystore imported"
        ;;
    esac
  fi

  # Use printf (no trailing newline) — geth's password parser treats each line as
  # a separate password and the trailing \n can be interpreted as an extra account.
  printf '%s' "$KEYSTORE_PASSWORD" > "$CONFIG_DIR/password.txt"
  # Container geth runs as UID 1000:1000. Make password + parent dir readable by it,
  # but keep host filesystem locked down via parent dir traversal:
  #   /opt/satuchain-validator       root:root 755  (allows traverse only)
  #   /opt/satuchain-validator/config root:root 755
  #   /opt/satuchain-validator/config/password.txt 1000:1000 600
  chown 1000:1000 "$CONFIG_DIR/password.txt"
  chmod 600 "$CONFIG_DIR/password.txt"
  chmod 755 "$CONFIG_DIR"

  # Persist auto-generated password into state for resume (manual passwords NOT saved)
  if [[ "$KEYSTORE_PASSWORD_AUTO" == "true" ]]; then
    save_state "KEYSTORE_PASSWORD" "$KEYSTORE_PASSWORD"
    save_state "KEYSTORE_PASSWORD_AUTO" "true"
  fi

  log "$(t account_ok)"
  report_status "keystore" "done" "Keystore ready for $VALIDATOR_ADDRESS"
}

# ════════════════════════════════════════════════════════════
# STEP 7 — Firewall (UFW if available, else skip)
# ════════════════════════════════════════════════════════════
setup_firewall() {
  step "$(t step_firewall)"
  if ! command -v ufw &>/dev/null; then
    apt-get install -y -qq ufw 2>/dev/null || { warn "$(t fw_skip)"; return; }
  fi

  # Only open ports — do NOT reset existing rules (avoid SSH lockout)
  ufw allow 22/tcp    comment "SSH"      > /dev/null 2>&1
  ufw allow 30303/tcp comment "P2P TCP"  > /dev/null 2>&1
  ufw allow 30303/udp comment "P2P UDP"  > /dev/null 2>&1

  # Enable only if not already active
  if ! ufw status | grep -q "Status: active"; then
    ufw default deny incoming  > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw --force enable         > /dev/null 2>&1
  fi

  log "$(t fw_ok)"
}

# ════════════════════════════════════════════════════════════
# STEP 8 — Create docker-compose.yml & start node
# ════════════════════════════════════════════════════════════
setup_compose_and_start() {
  step "$(t step_compose)"

  # Init genesis data (one-time)
  if [[ ! -d "$DATA_DIR/geth/chaindata" ]]; then
    info "Initializing genesis block..."
    # Same pattern as account import: bypass docker-entrypoint.sh (needs config.toml),
    # run as root (so geth can write to /data which is root-owned on host),
    # and wrap with set +e to survive non-zero exit under set -e pipefail.
    set +e
    docker run --rm \
      --entrypoint geth \
      --user root \
      -v "$DATA_DIR:/data" \
      -v "$CONFIG_DIR:/config" \
      "$BSC_IMAGE" \
      init --datadir /data /config/genesis.json
    GENESIS_RC=$?
    set -e
    if [[ $GENESIS_RC -ne 0 ]]; then
      report_status "genesis" "failed" "Genesis init failed (exit $GENESIS_RC)"
      die "Genesis initialization failed. Output above. Contact SatuChain admin."
    fi
    # Fix ownership so runtime container (UID 1000) can read+write
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    log "Genesis initialized"
  else
    info "Chaindata exists, skipping genesis init"
  fi

  # Pre-pull disk check — BSC image is ~800 MB, need at least 2 GB free
  PULL_DISK=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -d 'G ')
  if [[ "${PULL_DISK:-0}" -lt 2 ]]; then
    report_status "pull" "failed" "Not enough disk space (${PULL_DISK} GB free, need 2 GB)"
    die "Not enough disk space to pull Docker image (${PULL_DISK} GB free, need at least 2 GB). Free up space and re-run."
  fi
  # Check available memory (RAM + swap) before pull
  PULL_MEM=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') + $(grep SwapFree /proc/meminfo | awk '{print $2}') ))
  if [[ "${PULL_MEM:-0}" -lt 512000 ]]; then
    warn "Low memory available ($(( PULL_MEM / 1024 )) MB free). Attempting to free caches..."
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi

  info "$(t compose_pull)"
  report_status "pull" "started" "Pulling Docker image $BSC_IMAGE..."
  if ! docker pull "$BSC_IMAGE"; then
    report_status "pull" "failed" "docker pull failed — check disk space and memory"
    die "$(t compose_fail)"
  fi
  report_status "pull" "done" "Image pulled successfully"

  # Pre-flight: ensure ports geth needs (8545/8546/30303) are free.
  # Compose uses network_mode=host, so the container binds directly to host.
  # If a previous crashed container or stale process still holds 8545,
  # `docker compose up` succeeds but geth dies with "bind: address already in use".
  info "Checking for port conflicts (8545/8546/30303)..."
  # First: force-remove any old satuchain-validator container in whatever state
  docker rm -f satuchain-validator 2>/dev/null || true
  # Then: kill stale geth processes started by old crashed containers.
  # These are usually orphaned (re-parented to init) after docker rm -f.
  STALE_GETH=$(pgrep -f "^geth " 2>/dev/null || true)
  if [[ -n "$STALE_GETH" ]]; then
    warn "Killing stale geth process(es): $STALE_GETH"
    # shellcheck disable=SC2086
    kill -9 $STALE_GETH 2>/dev/null || true
    sleep 1
  fi
  # Re-verify port — if STILL in use, it's something else and we should NOT touch it.
  PORT_HOLDER=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:8545$/ {print $NF; exit}')
  if [[ -n "$PORT_HOLDER" ]]; then
    report_status "compose" "failed" "Port 8545 already in use by $PORT_HOLDER"
    warn "Port 8545 is bound by another process: $PORT_HOLDER"
    warn "Inspect with: sudo ss -tlnp '( sport = :8545 )'"
    die "Cannot start validator — release port 8545 first, then re-run installer."
  fi

  # Phase 1: Start in sync-only mode
  info "$(t compose_start)"
  report_status "compose" "started" "Starting validator container..."
  write_compose "sync"
  # Stop and remove existing container if present (idempotent re-run)
  docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" up -d
  if [[ $? -ne 0 ]]; then
    COMPOSE_ERR=$(docker compose -f "$COMPOSE_FILE" logs --tail=10 2>&1 | tail -5)
    report_status "compose" "failed" "docker compose up failed: $COMPOSE_ERR"
    warn "docker compose up failed — check logs: docker compose -f $COMPOSE_FILE logs"
    die "$(t compose_fail)"
  fi

  sleep 8
  if docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
    log "$(t compose_ok)"
    report_status "compose" "done" "Container $CONTAINER_NAME running"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✓ Node container berjalan / Node container is running${NC}"
    echo -e "  Container : ${CYAN}$CONTAINER_NAME${NC}"
    docker ps --filter "name=$CONTAINER_NAME" --format "  Status    : {{.Status}}\n  Image     : {{.Image}}" 2>/dev/null || true
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Node startup logs (10 baris pertama / first 10 lines):${NC}"
    docker logs "$CONTAINER_NAME" --tail=10 2>&1 || true
    echo ""
  else
    echo ""
    warn "Container tidak running setelah start / Container not running after start:"
    echo "──────────────────────────────────────────"
    docker logs "$CONTAINER_NAME" --tail=30 2>&1 || true
    docker compose -f "$COMPOSE_FILE" logs --tail=30 2>&1 || true
    echo "──────────────────────────────────────────"
    warn "docker ps -a:"
    docker ps -a 2>&1 || true
    COMPOSE_ERR=$(docker logs "$CONTAINER_NAME" 2>&1 | tail -3 || docker compose -f "$COMPOSE_FILE" logs --tail=3 2>&1)
    report_status "compose" "failed" "Container not running: $COMPOSE_ERR"
    die "$(t compose_fail)"
  fi

  # Phase 2: Wait for admin activation approval
  log "$(t sync_mode_start)"
  echo ""
  echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${BOLD}Node sedang sinkronisasi blockchain / Node is syncing${NC}          ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}                                                                 ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  Status sync akan ditampilkan setiap 30 detik.                  ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  Sync status will be shown every 30 seconds.                    ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}                                                                 ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  Kamu bisa tekan ${BOLD}Ctrl+C${NC} kapanpun — node tetap berjalan           ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  di background. Cek dashboard untuk melihat progress.           ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  You can press ${BOLD}Ctrl+C${NC} anytime — node keeps running in           ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  background. Check dashboard for progress.                      ${CYAN}│${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  info "$(t waiting_activation)"

  local waited=0
  while true; do
    # Check container still running
    if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "$CONTAINER_NAME"; then
      echo ""
      warn "⚠ Container berhenti / Container stopped unexpectedly!"
      echo "  Last logs:"
      docker logs "$CONTAINER_NAME" --tail=20 2>&1 || true
      report_status "node" "failed" "Container stopped unexpectedly"
      die "Node container stopped. Check logs above. Re-run installer after fixing the issue."
    fi

    STATUS=$($CURL_API -s --max-time 10 "$API_BASE/node-status?key=$VALIDATOR_KEY" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

    if [[ "$STATUS" == "approved" || "$STATUS" == "active" ]]; then
      log "$(t activation_approved)"
      break
    fi

    # Fallback: also check on-chain status directly. The API file `node-status.json`
    # only gets updated when admin clicks Approve in /admin UI — if admin signed via
    # Remix/stuscan/raw tx, API status stays stale forever. On-chain is source of truth.
    # Status enum: 0=None, 1=Pending, 2=Active, 3=Jailed, 4=Exiting, 5=Exited.
    CHAIN_STATUS=$(docker exec "$CONTAINER_NAME" sh -c \
      "geth attach --datadir /data --exec 'eth.call({to:\"$STAKING_CONTRACT_ADDR\",data:\"0xe9790d02000000000000000000000000${VALIDATOR_ADDRESS:2}\"})' 2>/dev/null | tr -d '\r\n\"'" \
      2>/dev/null || echo "")
    # getValidator returns a struct; status is the 5th uint8 (offset 0x80 = 4*32 bytes)
    # Easier: parse JSON-RPC via curl to public RPC — geth attach can be flaky.
    if [[ -z "$CHAIN_STATUS" || "$CHAIN_STATUS" == "0x" ]]; then
      STATUS_HEX=$($CURL_API -s --max-time 8 -X POST "$RPC_PUBLIC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$STAKING_CONTRACT_ADDR\",\"data\":\"0xe9790d02000000000000000000000000${VALIDATOR_ADDRESS:2}\"},\"latest\"],\"id\":1}" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))" 2>/dev/null || echo "")
      # status field at offset 4*32 = byte 128 (hex char 256+2=258). Each uint8 stored in 32-byte slot.
      # Result is 0x + 12 fields * 64 hex chars. status is field index 4 (0:addr,1:selfStake,2:totalDelegated,3:commission,4:status,...)
      if [[ -n "$STATUS_HEX" && "$STATUS_HEX" != "0x" ]]; then
        # field 4 → starts at hex char 2 + 4*64 = 258
        STATUS_NUM=$(printf '%d' "0x${STATUS_HEX:258:64}" 2>/dev/null || echo "0")
        if [[ "$STATUS_NUM" == "2" ]]; then
          log "On-chain status = Active (admin already approved). Activating..."
          # Also push to API so dashboard reflects
          $CURL_API -s --max-time 5 -X POST "$API_BASE/node-status-sync" \
            -H "Content-Type: application/json" \
            -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\"}" >/dev/null 2>&1 || true
          break
        fi
      fi
    fi

    # Print sync progress every 30 seconds
    LOCAL_BLOCK=$(docker exec "$CONTAINER_NAME" sh -c \
      'geth attach --datadir /data --exec "eth.blockNumber" 2>/dev/null | tr -d "\r\n"' \
      2>/dev/null || echo "?")
    PEERS=$(docker exec "$CONTAINER_NAME" sh -c \
      'geth attach --datadir /data --exec "net.peerCount" 2>/dev/null | tr -d "\r\n"' \
      2>/dev/null || echo "?")
    TS=$(date '+%H:%M:%S')
    echo -e "  [${TS}] Block: ${CYAN}${LOCAL_BLOCK}${NC} | Peers: ${CYAN}${PEERS}${NC} | Status: ${YELLOW}menunggu aktivasi admin / waiting admin activation${NC}"

    sleep 30
    waited=$(( waited + 30 ))
  done

  # Phase 3: Restart with validator (--mine) mode
  info "$(t starting_validator_mode)"
  write_compose "validator"
  docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null
  sleep 6

  # Confirm activation to API
  $CURL_API -s --max-time 10 -X POST "$API_BASE/node-activated" \
    -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\"}" > /dev/null 2>&1

  log "$(t validator_mode_ok)"
}

# ════════════════════════════════════════════════════════════
# STEP 9 — Monitor script (cron every 5 min)
# ════════════════════════════════════════════════════════════
setup_monitor() {
  step "$(t step_monitor)"

  cat > "$MONITOR_SCRIPT" << 'MONITOR'
#!/bin/bash
# SatuChain Validator Monitor v2.1 — auto sync health to dashboard + auto-update node image

INSTALL_DIR="/opt/satuchain-validator"
STATE_FILE="$INSTALL_DIR/.state"
API_BASE="https://staking.satuchain.com/api"
CONTAINER="satuchain-validator"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LOG_FILE="$INSTALL_DIR/logs/monitor.log"

load_state() { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true; }
log_m() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

VALIDATOR_ADDRESS=$(load_state VALIDATOR_ADDRESS)
VALIDATOR_KEY=$(load_state VALIDATOR_KEY)
PUBLIC_IP=$(load_state PUBLIC_IP)

[[ -z "$VALIDATOR_ADDRESS" ]] && { log_m "ERROR: state file missing"; exit 1; }

# ── Node health via docker exec ───────────────────────────────
NODE_ONLINE=false
LOCAL_BLOCK=0
PEER_COUNT=0
ENODE=""
LATENCY=0

if docker ps --filter "name=$CONTAINER" --filter "status=running" \
   --format "{{.Names}}" 2>/dev/null | grep -q "$CONTAINER"; then

  START_MS=$(date +%s%3N)
  IPC_OUT=$(docker exec "$CONTAINER" sh -c \
    'geth attach --datadir /data --exec "eth.blockNumber" 2>/dev/null | tr -d "\r\n"' \
    2>/dev/null || echo "")
  END_MS=$(date +%s%3N)
  LATENCY=$(( END_MS - START_MS ))

  if [[ "$IPC_OUT" =~ ^[0-9]+$ ]]; then
    NODE_ONLINE=true
    LOCAL_BLOCK=$IPC_OUT
    PEER_COUNT=$(docker exec "$CONTAINER" sh -c \
      'geth attach --datadir /data --exec "net.peerCount" 2>/dev/null | tr -d "\r\n"' \
      2>/dev/null || echo "0")
    [[ ! "$PEER_COUNT" =~ ^[0-9]+$ ]] && PEER_COUNT=0
    ENODE=$(docker exec "$CONTAINER" sh -c \
      'geth attach --datadir /data --exec "admin.nodeInfo.enode" 2>/dev/null | tr -d "\""' \
      2>/dev/null || echo "")
  fi
else
  log_m "WARN: container $CONTAINER not running"
fi

# ── Chain block via public RPC ────────────────────────────────
CHAIN_BLOCK=$(curl -s --max-time 10 -X POST "https://rpc-mainnet.satuchain.com" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null \
  || echo "0")

# ── Sync calc ─────────────────────────────────────────────────
SYNC_GAP=0; IS_SYNCED=false
if [[ $CHAIN_BLOCK -gt 0 && $LOCAL_BLOCK -gt 0 ]]; then
  SYNC_GAP=$(( CHAIN_BLOCK - LOCAL_BLOCK ))
  [[ $SYNC_GAP -le 10 ]] && IS_SYNCED=true
fi

log_m "block=$LOCAL_BLOCK chain=$CHAIN_BLOCK gap=$SYNC_GAP peers=$PEER_COUNT lat=${LATENCY}ms online=$NODE_ONLINE"

# ── Push health to dashboard (for charts) ────────────────────
# Retry up to 3 times on transient network failure (timeout, DNS hiccup).
PUSH=""
for attempt in 1 2 3; do
  PUSH=$(curl --ipv4 -s --max-time 15 --retry 2 --retry-delay 2 -X POST "$API_BASE/node-health-push" \
    -H "Content-Type: application/json" \
    -d "{
      \"address\":\"$VALIDATOR_ADDRESS\",
      \"key\":\"$VALIDATOR_KEY\",
      \"health\":{
        \"online\":$NODE_ONLINE,
        \"localBlock\":$LOCAL_BLOCK,
        \"chainBlock\":$CHAIN_BLOCK,
        \"syncGap\":$SYNC_GAP,
        \"isSynced\":$IS_SYNCED,
        \"latency\":$LATENCY,
        \"peerCount\":$PEER_COUNT,
        \"enode\":\"$ENODE\"
      }
    }" 2>&1)
  if echo "$PUSH" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok')" 2>/dev/null; then
    log_m "Health pushed OK (attempt $attempt) — block=$LOCAL_BLOCK gap=$SYNC_GAP peers=$PEER_COUNT"
    break
  fi
  log_m "WARN: health push attempt $attempt failed — $(echo "$PUSH" | head -c 200)"
  sleep $((attempt * 3))
done

# ── Update metadata ───────────────────────────────────────────
curl --ipv4 -s --max-time 15 -X POST "$API_BASE/validator-info" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"info\":{\"serverIp\":\"$PUBLIC_IP\",\"enode\":\"$ENODE\",\"lastPing\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
  > /dev/null 2>&1

# ── Auto report-ready when synced (one-time) ─────────────────
ALREADY_REPORTED=$(load_state REPORTED_READY)
if [[ "$IS_SYNCED" == "true" && "$ALREADY_REPORTED" != "true" ]]; then
  log_m "Fully synced! Reporting ready to dashboard..."
  RESULT=$(curl --ipv4 -s --max-time 15 -X POST "$API_BASE/validator-report-ready" \
    -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\"}" 2>/dev/null)
  if echo "$RESULT" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok')" 2>/dev/null; then
    echo "REPORTED_READY=true" >> "$STATE_FILE"
    log_m "report-ready sent! Admin will approve your validator."
  fi
fi

# ── Auto-update node image (check once per hour via lock file) ────────────────
UPDATE_LOCK="$INSTALL_DIR/.last-image-check"
NOW=$(date +%s)
LAST_CHECK=$(cat "$UPDATE_LOCK" 2>/dev/null || echo "0")
if (( NOW - LAST_CHECK > 3600 )); then
  echo "$NOW" > "$UPDATE_LOCK"
  # Fetch recommended image from dashboard API
  LATEST_IMAGE=$(curl --ipv4 -s --max-time 10 "$API_BASE/node-image" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('image',''))" 2>/dev/null || echo "")
  if [[ -n "$LATEST_IMAGE" ]]; then
    CURRENT_IMAGE=$(grep "image:" "$COMPOSE_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    if [[ -n "$CURRENT_IMAGE" && "$CURRENT_IMAGE" != "$LATEST_IMAGE" ]]; then
      log_m "New node image available: $LATEST_IMAGE (current: $CURRENT_IMAGE)"
      log_m "Pulling new image..."
      if docker pull "$LATEST_IMAGE" >> "$LOG_FILE" 2>&1; then
        # Update compose file with new image
        sed -i "s|image: .*|image: $LATEST_IMAGE|g" "$COMPOSE_FILE"
        docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1
        log_m "Node updated to $LATEST_IMAGE and restarted"
      else
        log_m "WARN: Failed to pull $LATEST_IMAGE"
      fi
    fi
  fi
fi

# ── Rotate log (keep last 1000 lines) ────────────────────────
if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
  tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
MONITOR

  chmod +x "$MONITOR_SCRIPT"

  # ── 1. Ensure cron daemon is installed + running ─────────────
  # Minimal VPS images sometimes ship without cron. Without cron, monitor.sh
  # never runs, dashboard stays "offline" forever even though node is fine.
  CRON_UNIT=""
  if systemctl list-unit-files 2>/dev/null | grep -qE '^cron\.service'; then
    CRON_UNIT="cron"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^crond\.service'; then
    CRON_UNIT="crond"
  fi
  if [[ -z "$CRON_UNIT" ]]; then
    info "Installing cron daemon..."
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y cron >/dev/null 2>&1 && CRON_UNIT="cron"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y cronie >/dev/null 2>&1 && CRON_UNIT="crond"
    fi
  fi
  if [[ -n "$CRON_UNIT" ]]; then
    systemctl enable --now "$CRON_UNIT" >/dev/null 2>&1 || true
  fi

  # ── 2. Register cron entry (replace existing satuchain entry) ─
  (crontab -l 2>/dev/null | grep -v "satuchain-monitor\|monitor.sh"; \
   echo "*/5 * * * * /bin/bash $MONITOR_SCRIPT") | crontab -

  # ── 3. Always-on systemd timer (belt + suspenders for unreliable cron) ─
  # If cron is broken / disabled / restricted (containerized hosts, some VPS),
  # the timer ensures we still push every 5 minutes.
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/satuchain-monitor.service <<UNIT
[Unit]
Description=SatuChain validator monitor (one-shot heartbeat)

[Service]
Type=oneshot
ExecStart=/bin/bash $MONITOR_SCRIPT
UNIT
    cat > /etc/systemd/system/satuchain-monitor.timer <<UNIT
[Unit]
Description=Run SatuChain validator monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now satuchain-monitor.timer >/dev/null 2>&1 || true
  fi

  # ── 4. Force first push NOW so dashboard turns online immediately ─
  info "Running first heartbeat push..."
  if /bin/bash "$MONITOR_SCRIPT" 2>&1 | tail -5; then
    log "First push sent. Dashboard will show online within 30 seconds."
  else
    warn "First push had non-zero exit. Check $LOG_DIR/monitor.log"
  fi

  # ── 5. Verify cron actually scheduled the entry ─
  if crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    log "Cron schedule registered (every 5 min)"
  else
    warn "Cron entry not visible — relying on systemd timer fallback"
  fi
  if systemctl is-active --quiet satuchain-monitor.timer 2>/dev/null; then
    log "Systemd timer active (every 5 min)"
  fi

  log "$(t monitor_ok)"
}

# ════════════════════════════════════════════════════════════
# STEP 10 — Send initial report
# ════════════════════════════════════════════════════════════
report_initial() {
  step "$(t step_report)"
  $CURL_API -s --max-time 15 -X POST "$API_BASE/validator-info" \
    -H "Content-Type: application/json" \
    -d "{
      \"address\":\"$VALIDATOR_ADDRESS\",
      \"key\":\"$VALIDATOR_KEY\",
      \"info\":{
        \"serverIp\":\"$PUBLIC_IP\",
        \"isSynced\":false,
        \"installedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"installerVersion\":\"2.0.0\",
        \"lastPing\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
      }
    }" > /dev/null 2>&1
  log "$(t report_ok)"

  # Run monitor immediately (background)
  sleep 8 && bash "$MONITOR_SCRIPT" &
}

# ════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║          $(t summary_title)                   ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Validator :${NC} $VALIDATOR_ADDRESS"
  echo -e "  ${BOLD}Server IP :${NC} $PUBLIC_IP"
  echo -e "  ${BOLD}Chain ID  :${NC} $CHAIN_ID"
  echo -e "  ${BOLD}Container :${NC} $CONTAINER_NAME"
  if [[ "$KEYSTORE_PASSWORD_AUTO" == "true" ]] && [[ -n "$KEYSTORE_PASSWORD" ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ Keystore password (auto-generated — SAVE THIS):${NC}"
    echo -e "    ${BOLD}$KEYSTORE_PASSWORD${NC}"
    echo -e "  ${YELLOW}Backup: cat $STATE_FILE | grep KEYSTORE_PASSWORD=${NC}"
  fi
  echo ""
  echo -e "  ${BOLD}$(t summary_next)${NC}"
  echo -e "  ${CYAN}✓${NC} $(t summary_s1)"
  echo -e "  ${CYAN}✓${NC} $(t summary_s2)"
  echo -e "  ${CYAN}✓${NC} $(t summary_s3)"
  echo ""
  echo -e "  ${BOLD}$(t summary_logs)${NC}"
  echo -e "  ${YELLOW}docker logs $CONTAINER_NAME -f${NC}"
  echo -e "  ${YELLOW}docker compose -f $COMPOSE_FILE ps${NC}"
  echo -e "  ${YELLOW}tail -f $LOG_DIR/monitor.log${NC}"
  echo ""
  echo -e "  ${BOLD}$(t summary_view)${NC}"
  echo -e "  ${CYAN}https://staking.satuchain.com${NC}"
  echo -e "  ${CYAN}https://stuscan.com/address/$VALIDATOR_ADDRESS${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════
# SELF-UPDATE CHECK
# ════════════════════════════════════════════════════════════
self_update() {
  # Skip self-update if running via curl|bash (no local file to replace)
  # Only update if invoked as a saved local script
  if [[ "${SATUCHAIN_SKIP_UPDATE:-}" == "1" ]]; then return; fi

  info "Checking for installer updates..."
  LATEST_TAG=$(curl -s --max-time 8 "$GITHUB_LATEST_API" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")

  if [[ -z "$LATEST_TAG" ]]; then
    warn "Could not check for updates (no internet or API unavailable). Continuing with v${INSTALLER_VERSION}."
    return
  fi

  # Strip leading 'v' for comparison
  LATEST_VER="${LATEST_TAG#v}"

  if [[ "$LATEST_VER" == "$INSTALLER_VERSION" ]]; then
    log "Installer is up to date (v${INSTALLER_VERSION})"
    return
  fi

  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  UPDATE TERSEDIA / UPDATE AVAILABLE                          ║${NC}"
  echo -e "${YELLOW}║                                                              ║${NC}"
  echo -e "${YELLOW}║  Versi saat ini / Current : v${INSTALLER_VERSION}                           ║${NC}"
  echo -e "${YELLOW}║  Versi terbaru  / Latest  : ${LATEST_TAG}                           ║${NC}"
  echo -e "${YELLOW}║                                                              ║${NC}"
  echo -e "${YELLOW}║  Mengunduh versi terbaru... / Downloading latest...          ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  NEW_SCRIPT=$(mktemp /tmp/satuchain-installer-XXXXXX.sh)
  if curl --ipv4 -fsSL --max-time 30 "$INSTALLER_URL" -o "$NEW_SCRIPT" 2>/dev/null; then
    chmod +x "$NEW_SCRIPT"
    log "Downloaded v${LATEST_TAG}. Restarting with new version..."
    echo ""
    # Re-exec with new script, skip update check to avoid infinite loop
    export SATUCHAIN_SKIP_UPDATE=1
    exec bash "$NEW_SCRIPT" "$@"
  else
    warn "Failed to download update. Continuing with v${INSTALLER_VERSION}."
    rm -f "$NEW_SCRIPT"
  fi
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
main() {
  print_banner
  self_update "$@"
  select_language
  detect_resume        # offer resume if previous install exists
  check_requirements   # HARD STOP if specs not met
  check_connectivity
  validate_key         # SECURITY GATE (skipped on resume)
  install_docker       # auto-install if missing
  setup_genesis
  setup_account
  setup_firewall
  setup_compose_and_start
  setup_monitor
  setup_backup         # daily backup of critical files (keystore, state, config)
  report_initial
  verify_peering       # sanity-check peers + auto-fix stale bootnode
  print_summary
}

# ════════════════════════════════════════════════════════════
# Critical-state backup (keystore + .state + password.txt + config.toml)
# ════════════════════════════════════════════════════════════
# WHAT we back up:
#   - keystore/UTC--*           (encrypted private key, ~5KB)
#   - .state                    (validator address, key, auto-password)
#   - config/password.txt       (decrypts the keystore)
#   - config/config.toml        (node config — easy to regenerate but small)
#   - config/genesis.json       (also easy to redownload — kept for offline restore)
# WHAT we DON'T back up:
#   - data/geth/chaindata       (GBs, redownloadable from peers)
#   - data/geth/lightchaindata  (same)
# Total backup size: ~10-50 KB. Cheap to keep many.
backup_validator() {
  local stamp ts dir tarball
  stamp=$(date +%Y%m%d-%H%M%S)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dir="$INSTALL_DIR/backups"
  mkdir -p "$dir"
  tarball="$dir/validator-$stamp.tar.gz"

  tar -czf "$tarball" \
    -C "$INSTALL_DIR" \
    --transform "s|^|$VALIDATOR_ADDRESS/|" \
    keystore .state config/password.txt config/config.toml config/genesis.json \
    2>/dev/null || true

  chmod 600 "$tarball"

  # Rotate: keep last 7 daily + last 4 hourly (cron may fire either)
  ls -t "$dir"/validator-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f

  echo "[$ts] Backup → $tarball ($(stat -c %s "$tarball" 2>/dev/null || stat -f %z "$tarball" 2>/dev/null) bytes)" >> "$INSTALL_DIR/logs/backup.log"
  echo "$tarball"
}

restore_validator() {
  local file=$1
  if [[ ! -f "$file" ]]; then die "Backup file not found: $file"; fi
  step "Restoring from backup: $file"
  # Stop any running container first to avoid keystore racing
  docker stop "$CONTAINER_NAME" 2>/dev/null || true

  # Extract directly into install dir (transform strips the addr/ prefix)
  tar -xzf "$file" -C "$INSTALL_DIR" --strip-components=1
  chown -R 1000:1000 "$INSTALL_DIR/keystore" 2>/dev/null || true
  chown 1000:1000 "$INSTALL_DIR/config/password.txt" 2>/dev/null || true
  chmod 600 "$INSTALL_DIR/config/password.txt" "$INSTALL_DIR/.state" 2>/dev/null || true

  log "Files restored. Re-run installer normally to bring container back up:"
  echo "  curl -fsSL https://staking.satuchain.com/install-validator.sh | sudo bash"
}

setup_backup() {
  step "Setup daily backup"
  local script="$INSTALL_DIR/backup.sh"
  cat > "$script" <<BACKUP
#!/bin/bash
# Auto-generated by install-validator.sh setup_backup
# Backs up critical validator state (keystore, .state, config) — NOT chaindata.
# Daily 02:00 (1 hour before core val1-4 backup window at 03:00).
INSTALL_DIR="$INSTALL_DIR"
CONTAINER_NAME="$CONTAINER_NAME"
VALIDATOR_ADDRESS="$VALIDATOR_ADDRESS"

stamp=\$(date +%Y%m%d-%H%M%S)
dir="\$INSTALL_DIR/backups"
mkdir -p "\$dir"
tarball="\$dir/validator-\$stamp.tar.gz"
tar -czf "\$tarball" -C "\$INSTALL_DIR" \\
  --transform "s|^|\$VALIDATOR_ADDRESS/|" \\
  keystore .state config/password.txt config/config.toml config/genesis.json \\
  2>/dev/null || true
chmod 600 "\$tarball"
ls -t "\$dir"/validator-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
size=\$(stat -c %s "\$tarball" 2>/dev/null || stat -f %z "\$tarball" 2>/dev/null)
echo "[\$(date '+%F %T')] Backup → \$tarball (\$size bytes)" >> "\$INSTALL_DIR/logs/backup.log"
BACKUP
  chmod +x "$script"
  mkdir -p "$INSTALL_DIR/logs"

  # Register cron — daily 02:00 (replace existing satuchain-backup entry)
  (crontab -l 2>/dev/null | grep -v "satuchain-backup\|backup.sh"; \
   echo "0 2 * * * /bin/bash $script") | crontab -

  # Also systemd timer as belt-and-suspenders (if cron missing)
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/satuchain-backup.service <<UNIT
[Unit]
Description=SatuChain validator daily critical-state backup

[Service]
Type=oneshot
ExecStart=/bin/bash $script
UNIT
    cat > /etc/systemd/system/satuchain-backup.timer <<UNIT
[Unit]
Description=Run satuchain-backup daily at 02:00 UTC

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now satuchain-backup.timer >/dev/null 2>&1 || true
  fi

  # Run once immediately so user has at least one backup right away
  backup_validator >/dev/null 2>&1 || true
  local count
  count=$(ls "$INSTALL_DIR/backups"/validator-*.tar.gz 2>/dev/null | wc -l)
  log "Backup schedule registered (daily 02:00 UTC), $count backup(s) on disk"
  echo -e "  Backups at: ${CYAN}$INSTALL_DIR/backups/${NC}"
  echo -e "  Restore: ${CYAN}curl ... | sudo bash -s -- --restore <file>${NC}"
}

# ════════════════════════════════════════════════════════════
# STEP 11 — Verify peer connectivity (auto-detect & fix common breakages)
# ════════════════════════════════════════════════════════════
# After everything is supposedly up, geth still needs to find peers. The most
# common reasons for peercount=0 forever:
#   1. config.toml has hostname bootnode left over from a prior install (geth
#      v1.7.2 enode parser only accepts literal IP). Auto-resolve + sed-replace.
#   2. UFW dropped outbound 30303 (rare; we only `allow` inbound, so outbound
#      should be unrestricted by default).
#   3. VPS provider firewall blocks 30303 (no fix from inside — print warning).
#
# We try to fix (1) automatically, then wait up to 60s for peers to appear.
verify_peering() {
  step "Verifying peer connectivity"

  local cfg="$CONFIG_DIR/config.toml"

  # ── 0. Compose needs --nat=extip:<PUBLIC_IP> or geth advertises 127.0.0.1 ─
  # Old installs (<2.5.7) wrote compose without --nat, so geth's enode says
  # 127.0.0.1 → bootnode peers can't dial back → peer count stays 0 forever.
  # If --nat missing, refresh PUBLIC_IP and rewrite compose.
  if [[ -f "$COMPOSE_FILE" ]] && ! grep -q "\-\-nat=extip:" "$COMPOSE_FILE"; then
    warn "Compose lacks --nat=extip — geth is advertising 127.0.0.1, peers can't reach back"
    if [[ -z "${PUBLIC_IP:-}" ]] || [[ "$PUBLIC_IP" == "unknown" ]]; then
      PUBLIC_IP=$(curl -4 -sf https://api.ipify.org --max-time 10 2>/dev/null \
        || curl -4 -sf https://ifconfig.me --max-time 10 2>/dev/null || echo "")
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
      warn "Could not auto-detect public IP — manual fix needed:"
      echo "  Edit $COMPOSE_FILE → add line under 'command:'"
      echo "    - --nat=extip:<your-public-ip>"
      echo "  Then: docker restart $CONTAINER_NAME"
    else
      log "Detected public IP: $PUBLIC_IP — rewriting compose with --nat=extip"
      write_compose "${MINING_MODE:-sync}"
      save_state "PUBLIC_IP" "$PUBLIC_IP"
      docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
      sleep 8
    fi
  fi

  # ── 1. Container running? ─────────────────────────────────────
  if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" \
       --format "{{.Names}}" 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    warn "Container $CONTAINER_NAME not running — starting..."
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 || {
      docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
    }
    sleep 6
  fi

  # ── 2. Bootnode in config — hostname → IP resolution ─────────
  local boot_line
  boot_line=$(grep BootstrapNodes "$cfg" 2>/dev/null | head -1 || echo "(not found)")
  echo -e "  ${BOLD}Bootnode in config:${NC} ${boot_line}"
  local boot_ip="46.250.225.9"
  local resolved
  resolved=$(getent hosts bootnode.satuchain.com 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$resolved" ]] && boot_ip="$resolved"
  echo -e "  ${BOLD}Resolved bootnode IP:${NC} $boot_ip"

  local restart_needed=false
  if grep -q "bootnode\.satuchain\.com" "$cfg" 2>/dev/null; then
    warn "Config has hostname-form bootnode — replacing with IP $boot_ip"
    sed -i "s|bootnode\.satuchain\.com|${boot_ip}|g" "$cfg"
    restart_needed=true
  fi

  # ── 3. Outbound connectivity (TCP + UDP) ──────────────────────
  local outbound_blocked=false
  if timeout 5 bash -c "echo > /dev/tcp/$boot_ip/30303" 2>/dev/null; then
    log "Outbound TCP 30303 → $boot_ip: reachable"
  else
    warn "Outbound TCP 30303 → $boot_ip: BLOCKED (VPS provider firewall)"
    outbound_blocked=true
  fi
  if command -v nc >/dev/null 2>&1; then
    if echo | timeout 3 nc -u -w 2 "$boot_ip" 30303 >/dev/null 2>&1; then
      log "Outbound UDP 30303 → $boot_ip: probable OK"
    else
      warn "Outbound UDP 30303 → $boot_ip: untestable (UDP is connectionless)"
    fi
  fi

  # ── 4. UFW inbound rules (idempotent) ────────────────────────
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 30303/tcp >/dev/null 2>&1 || true
    ufw allow 30303/udp >/dev/null 2>&1 || true
    log "UFW: 30303/tcp + 30303/udp allowed inbound"
  fi

  # ── 5. Listening on 30303? ────────────────────────────────────
  if ss -tlnp 2>/dev/null | awk '$4 ~ /:30303$/{print; exit}' | grep -q .; then
    log "Container binding 30303/tcp on host: yes"
  else
    warn "Container not listening on 30303/tcp — geth may not have started P2P yet"
  fi

  # ── 6. Restart if config changed ─────────────────────────────
  if [[ "$restart_needed" == "true" ]]; then
    info "Restarting container to apply config change..."
    docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sleep 8
  fi

  # 6.5 removed — peer-helper register moved to AFTER the peer wait below.
  # Outbound TCP test passing doesn't mean discovery actually works (UDP
  # could still be blocked, or enode handshake fails). We decide based on
  # actual peer count after 90s of trying.

  # ── 7. Poll peer count for up to 90s ──────────────────────────
  info "Waiting for peer discovery (up to 90s)..."
  local elapsed=0 peers=0 block=0
  while (( elapsed < 90 )); do
    peers=$(docker exec "$CONTAINER_NAME" sh -c \
      'geth attach --datadir /data --exec "net.peerCount" 2>/dev/null | tr -d "\r\n"' \
      2>/dev/null | grep -oE '^[0-9]+$' || echo "0")
    block=$(docker exec "$CONTAINER_NAME" sh -c \
      'geth attach --datadir /data --exec "eth.blockNumber" 2>/dev/null | tr -d "\r\n"' \
      2>/dev/null | grep -oE '^[0-9]+$' || echo "0")
    if (( peers > 0 )); then
      echo ""
      log "Connected to $peers peer(s), local block: $block."
      log "Sync will continue in background. Validator becomes authorized after syncing past the addValidator epoch (~block 1.32M+)."
      # Push immediately to dashboard so user sees fresh state without waiting 5min cron
      push_dashboard_state || true
      return 0
    fi
    sleep 6
    elapsed=$(( elapsed + 6 ))
    echo -n "."
  done
  echo ""
  warn "Still 0 peers after 90s — discovery probably failing (UDP blocked or enode handshake issue)."

  # Last-resort: register as peer-helper so core validators dial us back.
  # This works around any kind of outbound discovery failure (UDP-block, asymmetric
  # filter, ISP throttle, etc) by making the connection inbound from validator POV.
  info "Trying peer-helper fallback — core validators (val1-4) will dial us back"
  local enode=""
  for try in 1 2 3; do
    enode=$(docker exec "$CONTAINER_NAME" sh -c \
      'geth attach --datadir /data --exec "admin.nodeInfo.enode" 2>/dev/null' \
      2>/dev/null | tr -d '"\r\n' || echo "")
    [[ -n "$enode" && "$enode" =~ @127\.0\.0\.1: ]] && enode=""
    [[ -n "$enode" ]] && break
    sleep 4
  done
  if [[ -z "$enode" ]]; then
    warn "Could not read enode from geth — geth may not be running. Try: docker logs $CONTAINER_NAME --tail 30"
  else
    echo "  Registering enode: ${enode:0:80}..."
    local resp
    resp=$($CURL_API -s --max-time 8 -X POST "$API_BASE/peer-helper" \
      -H "Content-Type: application/json" \
      -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"enode\":\"$enode\"}" 2>&1 || echo "")
    if echo "$resp" | grep -q '"ok":true'; then
      log "Registered with peer-helper. Cores will dial back within 60s — wait + check 'docker exec satuchain-validator sh -c \"geth attach --datadir /data --exec net.peerCount\"'."
    else
      warn "peer-helper register failed: $resp"
    fi
  fi
  echo ""
  echo -e "  ${BOLD}Last 15 geth log lines:${NC}"
  docker logs "$CONTAINER_NAME" --tail 15 2>&1 | sed 's/^/    /'

  # Still push current state — let dashboard reflect the reality (offline / 0 peers)
  push_dashboard_state || true
}

# Read live state from local geth + POST to /api/node-health-push so dashboard
# updates immediately. Cron monitor.sh also does this every 5 min; we trigger
# right after install/--fix to avoid 5 min stale window.
push_dashboard_state() {
  [[ -z "${VALIDATOR_ADDRESS:-}" || -z "${VALIDATOR_KEY:-}" ]] && return 1
  local lb pc en cb online
  lb=$(docker exec "$CONTAINER_NAME" sh -c 'geth attach --datadir /data --exec "eth.blockNumber" 2>/dev/null | tr -d "\r\n"' 2>/dev/null | grep -oE '^[0-9]+$' || echo "0")
  pc=$(docker exec "$CONTAINER_NAME" sh -c 'geth attach --datadir /data --exec "net.peerCount" 2>/dev/null | tr -d "\r\n"' 2>/dev/null | grep -oE '^[0-9]+$' || echo "0")
  en=$(docker exec "$CONTAINER_NAME" sh -c 'geth attach --datadir /data --exec "admin.nodeInfo.enode" 2>/dev/null' 2>/dev/null | tr -d '"\r\n' || echo "")
  cb=$($CURL_API -s --max-time 5 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_PUBLIC" 2>/dev/null \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0")
  online="true"
  [[ "$pc" -eq 0 || "$lb" -eq 0 ]] && online="true"  # container running counts as online; sync state separate
  info "Pushing live state to dashboard (block=$lb peers=$pc chain=$cb)..."
  $CURL_API -s --max-time 8 -X POST -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"health\":{\"online\":$online,\"localBlock\":$lb,\"chainBlock\":$cb,\"latency\":3,\"peerCount\":$pc,\"enode\":\"$en\"}}" \
    "$API_BASE/node-health-push" >/dev/null 2>&1 || true
  # Also push validator-info so any new fields (enode, lastPing) propagate
  $CURL_API -s --max-time 8 -X POST -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"info\":{\"serverIp\":\"${PUBLIC_IP:-}\",\"enode\":\"$en\",\"lastPing\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"isSynced\":$([ "$cb" -gt 0 ] && [ "$lb" -gt 0 ] && [ $((cb-lb)) -le 10 ] && echo true || echo false)}}" \
    "$API_BASE/validator-info" >/dev/null 2>&1 || true
  log "Dashboard pushed."
}

# ════════════════════════════════════════════════════════════
# Sub-commands
# ════════════════════════════════════════════════════════════
# Usage:
#   curl ... | sudo bash               → full install
#   curl ... | sudo bash -s -- --fix   → only diagnose + fix peering (no reinstall)
#   curl ... | sudo bash -s -- --status → only print current node state
case "${1:-}" in
  --fix|fix)
    print_banner
    select_language
    if [[ ! -f "$STATE_FILE" ]]; then
      die "No install state found at $STATE_FILE. Run full installer first."
    fi
    VALIDATOR_ADDRESS=$(load_state VALIDATOR_ADDRESS)
    VALIDATOR_KEY=$(load_state VALIDATOR_KEY)
    BOOTNODE=$(load_state BOOTNODE)
    PUBLIC_IP=$(load_state PUBLIC_IP)
    verify_peering
    # Force monitor.sh to send a fresh heartbeat right now so dashboard reflects
    # current state without waiting for next 5-min cron tick.
    if [[ -x "$MONITOR_SCRIPT" ]]; then
      info "Running monitor.sh for immediate dashboard refresh..."
      /bin/bash "$MONITOR_SCRIPT" 2>&1 | tail -5 || true
    fi
    exit 0
    ;;
  --push|push)
    # Run monitor.sh once. Useful when dashboard shows stale data.
    if [[ ! -x "$MONITOR_SCRIPT" ]]; then die "monitor.sh not found at $MONITOR_SCRIPT — run full installer first"; fi
    /bin/bash "$MONITOR_SCRIPT"
    tail -5 "$LOG_DIR/monitor.log" 2>/dev/null
    exit 0
    ;;
  --status|status)
    if [[ ! -f "$STATE_FILE" ]]; then die "No install state found"; fi
    echo "Container: $(docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format '{{.Names}} {{.Status}}' 2>/dev/null || echo not running)"
    echo "Local block: $(docker exec "$CONTAINER_NAME" sh -c 'geth attach --datadir /data --exec "eth.blockNumber" 2>/dev/null' 2>/dev/null || echo '?')"
    echo "Peers: $(docker exec "$CONTAINER_NAME" sh -c 'geth attach --datadir /data --exec "net.peerCount" 2>/dev/null' 2>/dev/null || echo '?')"
    exit 0
    ;;
  --backup|backup)
    if [[ ! -f "$STATE_FILE" ]]; then die "No install state found"; fi
    VALIDATOR_ADDRESS=$(load_state VALIDATOR_ADDRESS)
    out=$(backup_validator)
    log "Backup written: $out"
    ls -la "$INSTALL_DIR/backups/" 2>/dev/null | head -10
    exit 0
    ;;
  --restore|restore)
    file="${2:-}"
    if [[ -z "$file" ]]; then
      echo "Usage: ... --restore /path/to/validator-YYYYMMDD-HHMMSS.tar.gz"
      echo ""
      echo "Available backups on this host:"
      ls -la "$INSTALL_DIR/backups/" 2>/dev/null | head -15
      exit 1
    fi
    restore_validator "$file"
    exit 0
    ;;
  *)
    main "$@"
    ;;
esac
