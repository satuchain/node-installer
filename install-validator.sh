#!/bin/bash
# ============================================================
# SatuChain Mainnet — Validator Node Installer
# Version: 2.1.0 — Docker-based deployment
# Usage : curl -fsSL https://raw.githubusercontent.com/satuchain/node-installer/main/install-validator.sh | sudo bash
# Min req: 2 vCPU / 2 GB RAM / 50 GB SSD  |  Rec: 4 vCPU / 4 GB RAM / 100 GB SSD
# ============================================================

set -euo pipefail

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
API_BASE="https://staking.satuchain.com/api"
RPC_PUBLIC="https://rpc-mainnet.satuchain.com"
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

# Minimum requirements — HARD STOP if not met
# Minimum: 2 vCPU / 2 GB RAM / 15 GB Disk
# Recommended: 4 vCPU / 4 GB RAM / 100 GB Disk
REQ_CPU=2
REQ_RAM_GB=2
REQ_DISK_GB=15

# ── State helpers ────────────────────────────────────────────
save_state() { echo "$1=$2" >> "$STATE_FILE"; }
load_state()  { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true; }

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
    id:account_method) echo "Pilih metode import:" ;;
    id:account_opt1)   echo "  1) Import private key" ;;
    id:account_opt2)   echo "  2) Import file keystore (UTC--...)" ;;
    id:account_pk)     echo "Private key (tanpa 0x):" ;;
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
    en:account_method) echo "Select import method:" ;;
    en:account_opt1)   echo "  1) Import private key" ;;
    en:account_opt2)   echo "  2) Import keystore file (UTC--...)" ;;
    en:account_pk)     echo "Private key (without 0x):" ;;
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
  echo -e "${BOLD}  SatuChain Mainnet — Validator Node Installer v2.0.0${NC}"
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
    echo -e "  ${YELLOW}→ Solution: Upgrade your VPS to at least 2 vCPU${NC}"
    echo -e "  ${YELLOW}  Example: DigitalOcean Basic 2vCPU (\$18/mo)${NC}"
    echo -e "  ${YELLOW}           Hetzner CPX11 2vCPU (€4.5/mo)${NC}"
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
    echo -e "  ${YELLOW}  Recommended VPS: Hetzner CPX21 €6/mo · DO 2GB \$18/mo · Contabo VPS S \$7/mo${NC}"
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
  curl -s --max-time 10 "$API_BASE/health" 2>/dev/null | python3 -c \
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
  STU_MET=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['stu']['met'])" 2>/dev/null || echo "False")
  STU_STAKED=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['stu']['staked'])" 2>/dev/null || echo "0")
  USDT_MET=$(echo "$REQ_RESPONSE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['requirements']['usdt']['met'])" 2>/dev/null || echo "False")
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

  if [[ "$STU_MET" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} 500,000 STU self-stake   (staked: ${STU_STAKED} STU)"
  else
    echo -e "  ${RED}[✗]${NC} 500,000 STU self-stake   (staked: ${STU_STAKED} STU — insufficient)"
  fi

  if [[ "$USDT_MET" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} 2,000 USDT deposit       (verified by admin)"
  else
    echo -e "  ${RED}[✗]${NC} 2,000 USDT deposit       (not yet verified — contact SatuChain admin)"
  fi

  if [[ "$ADMIN_MET" == "True" ]]; then
    echo -e "  ${GREEN}[✓]${NC} Admin approval           (key issued — ready)"
  else
    echo -e "  ${RED}[✗]${NC} Admin approval           (waiting — admin must issue your key)"
  fi
  echo -e "  ────────────────────────────────────────────────"
  echo ""

  [[ "$CAN_INSTALL" == "True" ]] \
    || die "Requirements not met. Complete all 3 requirements above, then re-run this installer."

  log "All requirements verified — proceeding with installation"

  echo -e "${BOLD}$(t key_prompt_key)${NC}"
  read -r -s VALIDATOR_KEY 2>/dev/null || die "No input"
  echo ""

  [[ "$VALIDATOR_KEY" =~ ^satu-val-[0-9a-f]{40}$ ]] \
    || die "$(t key_invalid_fmt): key must start with satu-val-"

  SERVER_ID=$(cat /etc/machine-id 2>/dev/null || hostname | md5sum | cut -c1-16)
  PUBLIC_IP=$(curl -sf https://api.ipify.org --max-time 10 2>/dev/null \
           || curl -sf https://ifconfig.me --max-time 10 2>/dev/null \
           || echo "unknown")

  info "Validating with SatuChain server..."
  RESPONSE=$(curl -s --max-time 15 -X POST "$API_BASE/validate-key" \
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

  # Fetch bootnode from server response (never hardcoded)
  BOOTNODE=$(echo "$RESPONSE" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('bootnode',''))" 2>/dev/null || echo "")
  [[ -z "$BOOTNODE" ]] && die "Cannot retrieve network bootnode from server"

  # Save state
  mkdir -p "$INSTALL_DIR"
  > "$STATE_FILE"
  save_state "VALIDATOR_ADDRESS" "$VALIDATOR_ADDRESS"
  save_state "VALIDATOR_KEY"     "$VALIDATOR_KEY"
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
    return
  fi

  info "$(t docker_install)"

  # Install via official Docker script (supports Ubuntu, Debian, CentOS, Fedora)
  curl -fsSL https://get.docker.com | sh 2>/dev/null \
    || die "Docker installation failed. Try manually: https://docs.docker.com/engine/install/"

  # Enable + start Docker service
  systemctl enable docker --now 2>/dev/null || service docker start 2>/dev/null || true

  # Wait for Docker to be ready
  local retries=10
  while ! docker info &>/dev/null 2>&1; do
    sleep 2
    retries=$(( retries - 1 ))
    [[ $retries -le 0 ]] && die "Docker started but not responding"
  done

  log "$(t docker_ok): $(docker --version)"
}

# ════════════════════════════════════════════════════════════
# STEP 5 — Download genesis & write config
# ════════════════════════════════════════════════════════════
setup_genesis() {
  step "$(t step_genesis)"
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$KEYSTORE_DIR" "$LOG_DIR"

  info "$(t genesis_dl)"
  curl -sfL "$API_BASE/genesis" --max-time 30 -o "$CONFIG_DIR/genesis.json" 2>/dev/null \
    || die "$(t genesis_fail)"

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

  ADDR_LOWER=$(echo "$VALIDATOR_ADDRESS" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')
  EXISTING=$(find "$KEYSTORE_DIR" -iname "*${ADDR_LOWER}*" 2>/dev/null | head -1 || true)

  if [[ -n "$EXISTING" ]]; then
    info "$(t account_exists)"
    echo -e "${BOLD}$(t account_exist_pw)${NC}"
    read -r -s KEYSTORE_PASSWORD 2>/dev/null; echo ""
  else
    echo ""
    echo -e "$(t account_method)"
    echo -e "${BOLD}$(t account_opt1)${NC}"
    echo -e "${BOLD}$(t account_opt2)${NC}"
    read -r -p "  [1/2]: " OPT 2>/dev/null || OPT="1"

    case $OPT in
      1)
        echo -e "${BOLD}$(t account_pk)${NC}"
        read -r -s PRIVKEY; echo ""
        echo -e "${BOLD}$(t account_pw)${NC}"
        read -r -s KEYSTORE_PASSWORD; echo ""
        echo -e "${BOLD}$(t account_pw2)${NC}"
        read -r -s KP2; echo ""
        [[ "$KEYSTORE_PASSWORD" == "$KP2" ]] || die "$(t account_pw_err)"

        # Use Docker to import — secure tmpdir (mode 700, not world-readable /tmp)
        SECURE_TMP=$(mktemp -d)
        chmod 700 "$SECURE_TMP"
        echo "$PRIVKEY" > "$SECURE_TMP/.pk"
        echo "$KEYSTORE_PASSWORD" > "$SECURE_TMP/.pw"
        chmod 600 "$SECURE_TMP/.pk" "$SECURE_TMP/.pw"
        docker run --rm \
          -v "$KEYSTORE_DIR:/keystore" \
          -v "$SECURE_TMP/.pk:/tmp/pk.txt:ro" \
          -v "$SECURE_TMP/.pw:/tmp/pw.txt:ro" \
          "$BSC_IMAGE" \
          account import --keystore /keystore --password /tmp/pw.txt /tmp/pk.txt \
          2>/dev/null
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
      *)
        die "Invalid option" ;;
    esac
  fi

  echo "$KEYSTORE_PASSWORD" > "$CONFIG_DIR/password.txt"
  chmod 600 "$CONFIG_DIR/password.txt"
  log "$(t account_ok)"
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
    docker run --rm \
      -v "$DATA_DIR:/data" \
      -v "$CONFIG_DIR:/config" \
      "$BSC_IMAGE" \
      init --datadir /data /config/genesis.json 2>/dev/null
    log "Genesis initialized"
  else
    info "Chaindata exists, skipping genesis init"
  fi

  # Write docker-compose.yml — SYNC ONLY mode (no --mine until admin approves)
  write_compose() {
    local mode=$1  # "sync" or "validator"
    cat > "$COMPOSE_FILE" <<COMPOSE
services:
  $CONTAINER_NAME:
    image: $BSC_IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    network_mode: host
    volumes:
      - $DATA_DIR:/data
      - $CONFIG_DIR:/config
      - $KEYSTORE_DIR:/data/keystore
      - $LOG_DIR:/logs
    command:
      - --config=/config/config.toml
      - --networkid=$CHAIN_ID
$([ "$mode" = "validator" ] && echo "      - --mine
      - --miner.etherbase=$VALIDATOR_ADDRESS
      - --unlock=$VALIDATOR_ADDRESS
      - --password=/config/password.txt")
      - --bootnodes=$BOOTNODE
      - --verbosity=3
      - --log.file=/logs/geth.log
      - --log.rotate=true
      - --log.maxsize=100
      - --log.maxbackups=7
COMPOSE
  }

  info "$(t compose_pull)"
  docker pull "$BSC_IMAGE" 2>/dev/null

  # Phase 1: Start in sync-only mode
  info "$(t compose_start)"
  write_compose "sync"
  docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

  sleep 6
  docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format "{{.Names}}" \
    | grep -q "$CONTAINER_NAME" \
    && log "$(t compose_ok)" \
    || die "$(t compose_fail)"

  # Phase 2: Wait for admin activation approval
  log "$(t sync_mode_start)"
  echo ""
  info "$(t waiting_activation)"

  local waited=0
  while true; do
    STATUS=$(curl -s --max-time 10 "$API_BASE/node-status?key=$VALIDATOR_KEY" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

    if [[ "$STATUS" == "approved" ]]; then
      log "$(t activation_approved)"
      break
    fi

    # Print progress every 5 minutes
    if (( waited % 300 == 0 && waited > 0 )); then
      info "$(t still_waiting) (${waited}s)"
    fi

    sleep 30
    waited=$(( waited + 30 ))
  done

  # Phase 3: Restart with validator (--mine) mode
  info "$(t starting_validator_mode)"
  write_compose "validator"
  docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null
  sleep 6

  # Confirm activation to API
  curl -s --max-time 10 -X POST "$API_BASE/node-activated" \
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
# SatuChain Validator Monitor v2.0 — auto sync health to dashboard

INSTALL_DIR="/opt/satuchain-validator"
STATE_FILE="$INSTALL_DIR/.state"
API_BASE="https://staking.satuchain.com/api"
CONTAINER="satuchain-validator"
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
PUSH=$(curl -s --max-time 15 -X POST "$API_BASE/node-health-push" \
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
  }" 2>/dev/null)
echo "$PUSH" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok')" 2>/dev/null \
  && log_m "Health pushed OK" \
  || log_m "WARN: health push failed — $PUSH"

# ── Update metadata ───────────────────────────────────────────
curl -s --max-time 15 -X POST "$API_BASE/validator-info" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\",\"info\":{\"serverIp\":\"$PUBLIC_IP\",\"enode\":\"$ENODE\",\"lastPing\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
  > /dev/null 2>&1

# ── Auto report-ready when synced (one-time) ─────────────────
ALREADY_REPORTED=$(load_state REPORTED_READY)
if [[ "$IS_SYNCED" == "true" && "$ALREADY_REPORTED" != "true" ]]; then
  log_m "Fully synced! Reporting ready to dashboard..."
  RESULT=$(curl -s --max-time 15 -X POST "$API_BASE/validator-report-ready" \
    -H "Content-Type: application/json" \
    -d "{\"address\":\"$VALIDATOR_ADDRESS\",\"key\":\"$VALIDATOR_KEY\"}" 2>/dev/null)
  if echo "$RESULT" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok')" 2>/dev/null; then
    echo "REPORTED_READY=true" >> "$STATE_FILE"
    log_m "report-ready sent! Admin will approve your validator."
  fi
fi

# ── Rotate log (keep last 1000 lines) ────────────────────────
if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
  tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
MONITOR

  chmod +x "$MONITOR_SCRIPT"

  # Register cron — replace existing satuchain entry
  (crontab -l 2>/dev/null | grep -v "satuchain-monitor\|monitor.sh"; \
   echo "*/5 * * * * /bin/bash $MONITOR_SCRIPT") | crontab -

  log "$(t monitor_ok)"
}

# ════════════════════════════════════════════════════════════
# STEP 10 — Send initial report
# ════════════════════════════════════════════════════════════
report_initial() {
  step "$(t step_report)"
  curl -s --max-time 15 -X POST "$API_BASE/validator-info" \
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
# MAIN
# ════════════════════════════════════════════════════════════
main() {
  print_banner
  select_language
  check_requirements   # HARD STOP if specs not met
  check_connectivity
  validate_key         # SECURITY GATE
  install_docker       # auto-install if missing
  setup_genesis
  setup_account
  setup_firewall
  setup_compose_and_start
  setup_monitor
  report_initial
  print_summary
}

main "$@"
