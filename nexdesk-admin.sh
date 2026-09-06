#!/usr/bin/env bash
#
# NexDesk — interactive admin menu
#
# Run as root:
#   sudo nexdesk                 # open the full menu
#   sudo nexdesk info            # print connection info (link + password)
#   sudo nexdesk status          # print the 4 services' state
#
# The script is usually symlinked to /usr/local/bin/nexdesk, so typing
# `nexdesk` from anywhere on the server opens the menu.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the install directory from our own real location (works via symlink)
# ---------------------------------------------------------------------------
REAL="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
NX_DIR="${NX_DIR:-$(cd "$(dirname "$REAL")" && pwd)}"
CFG_DIR="$NX_DIR/config"
PASS_FILE="$CFG_DIR/pass.txt"
WEBPATH_FILE="$CFG_DIR/webpath.txt"
GATEWAY_UNIT="/etc/systemd/system/nexdesk-gateway.service"
SVC_BASE="nexdesk"

# ---------------------------------------------------------------------------
# Colours / helpers
# ---------------------------------------------------------------------------
R='\e[0m'; B='\e[1m'; D='\e[2m'
CY='\e[36m'; GR='\e[32m'; YE='\e[33m'; RD='\e[31m'; MG='\e[35m'; WH='\e[97m'

info()  { echo -e "${CY}  [i]${R} $*"; }
ok()    { echo -e "${GR}  [ok]${R} $*"; }
warn()  { echo -e "${YE}  [!]${R} $*"; }
fail()  { echo -e "${RD}  [x] $*${R}"; }
line()  { echo -e "${D}  ──────────────────────────────────────────────────${R}"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RD}  This admin menu must run as root.${R}"
    echo -e "  Try: ${B}sudo nexdesk${R}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Small readers
# ---------------------------------------------------------------------------
first_line() { sed -n '1p' "$1" 2>/dev/null | tr -d '\r' || echo ""; }

webpath_val() { local v; v="$(first_line "$WEBPATH_FILE")"; printf '%s' "${v:-?}"; }
pass_val()    { first_line "$PASS_FILE"; }

port_val() {
  local p
  p="$(sed -n 's/^Environment=PORT=\([0-9][0-9]*\)$/\1/p' "$GATEWAY_UNIT" 2>/dev/null | head -1)"
  echo "${p:-8087}"
}

# HTTPS is served only when the gateway unit declares HTTPS_PORT (+ TLS files).
https_port_val() {
  sed -n 's/^Environment=HTTPS_PORT=\([0-9][0-9]*\)$/\1/p' "$GATEWAY_UNIT" 2>/dev/null | head -1
}

public_ip() {
  curl -4 -fsSL --max-time 4 https://api.ipify.org 2>/dev/null || true
}
local_ips() { hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'; }

# ---------------------------------------------------------------------------
# Banners / rendering
# ---------------------------------------------------------------------------
banner() {
  printf '\033[2J\033[H' 2>/dev/null || clear 2>/dev/null || true
  echo
  echo -e "    ${CY}███╗   ██╗███████╗██╗  ██╗${MG}██████╗ ███████╗███████╗██╗  ██╗${R}"
  echo -e "    ${CY}████╗  ██║██╔════╝╚██╗██╔╝${MG}██╔══██╗██╔════╝██╔════╝██║ ██╔╝${R}"
  echo -e "    ${CY}██╔██╗ ██║█████╗   ╚███╔╝ ${MG}██║  ██║█████╗  ███████╗█████╔╝${R}"
  echo -e "    ${CY}██║╚██╗██║██╔══╝   ██╔██╗ ${MG}██║  ██║██╔══╝  ╚════██║██╔═██╗${R}"
  echo -e "    ${CY}██║ ╚████║███████╗██╔╝ ██╗${MG}██████╔╝███████╗███████║██║  ██╗${R}"
  echo -e "    ${CY}╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝${MG}╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝${R}"
  echo
  echo -e "  ${B}${WH}Self-hosted virtual browser · Admin console${R}"
  line
}

banner_top() {
  printf '\033[2J\033[H' 2>/dev/null || clear 2>/dev/null || true
  banner
}

# ---------------------------------------------------------------------------
# Service status
# ---------------------------------------------------------------------------
service_state() {
  local s="$1" st col sc
  st="$(systemctl is-active "$s" 2>/dev/null || true)"
  sc="$GR"
  case "$st" in
    active)      col="${GR}●";;
    activating)  col="${YE}◐"; sc="$YE";;
    failed)      col="${RD}✕"; sc="$RD";;
    inactive)    col="${D}○"; sc="$R";;
    *)           col="${D}○"; sc="${YE}"; st="unknown";;
  esac
  printf '  '; printf '%b' "$col"
  printf ' %-20s ' "$s"
  printf '%b%s%b\n' "$sc" "$st" "$R"
}

show_status() {
  echo
  echo -e "  ${B}${CY}Service status${R}"
  line
  for s in nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway; do
    service_state "$s"
  done
  echo
}

# ---------------------------------------------------------------------------
# Connection info
# ---------------------------------------------------------------------------
show_info() {
  local wp pp pport https ip note extra=""
  wp="$(webpath_val)"
  pp="$(pass_val)"
  pport="$(port_val)"
  https="$(https_port_val)"
  ip="$(public_ip)"
  if [[ -z "$ip" ]]; then
    ip="$(local_ips | head -1)"
    extra="${RD}  (public IP not reachable from this box — using a local IP)${R}"
  fi
  banner
  echo -e "  ${B}${CY}Connection info${R}"
  line
  echo -e "  ${B}Secret web path :${R} ${YE}/${wp}${R}"
  echo -e "  ${B}HTTP  port      :${R} ${pport}"
  [[ -n "$https" ]] && echo -e "  ${B}HTTPS port      :${R} ${https}"
  echo -e "  ${B}Public IP       :${R} ${WH}${ip}${R}"
  [[ -n "$extra" ]] && echo -e "$extra"
  line
  echo -e "  ${B}${GR}Open in your browser:${R}"
  echo
  echo -e "   ${B}${WH}  http://${ip}:${pport}/${wp}${R}"
  if [[ -n "$https" ]]; then
    echo -e "   ${B}${WH}  https://${ip}:${https}/${wp}${R}"
    echo -e "   ${D}  (https uses a self-signed cert — accept the one-time warning)${R}"
  fi
  echo
  line
  echo -e "  ${B}Password:${R}  ${MG}${pp}${R}"
  echo
  echo -e "  ${YE}Keep these links and password secret. Anyone holding both can${R}"
  echo -e "  ${YE}reach this virtual browser. Root and unknown URLs return 404.${R}"
  echo
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
restart_all() {
  echo
  info "Restarting NexDesk services..."
  systemctl restart nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway
  sleep 2
  show_status
}

# ---------------------------------------------------------------------------
# Secrets writers (kept owner-only, owned by the service user)
# ---------------------------------------------------------------------------
write_secret() { # $1 = file  $2 = value
  umask 077
  printf '%s\n' "$2" > "$1"
  chown nexdesk:nexdesk "$1" 2>/dev/null || true
  chmod 600 "$1" 2>/dev/null || true
}

gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 12 | tr '+/' 'Aa' | tr -d '=' | tr -d '\n'
  else
    head -c 18 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16
  fi
}
gen_hex() { # $1 = bytes
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"; else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

change_password() {
  banner
  echo -e "  ${B}${CY}Change password${R}"
  line
  echo -e "  ${B}1)${R} Generate a strong random password"
  echo -e "  ${B}2)${R} Type my own password"
  read -r -p "  Choose [1/2]: " m
  local newpass=""
  case "$m" in
    1)
      newpass="$(gen_pass)"
      echo -e "  Generated: ${MG}${newpass}${R}"
      ;;
    2)
      read -r -s -p "  New password: " newpass; echo
      [[ -n "$newpass" ]] || { fail "Password cannot be empty."; return; }
      read -r -s -p "  Confirm again: " c; echo
      [[ "$newpass" == "$c" ]] || { fail "Passwords do not match."; return; }
      ;;
    *) fail "Invalid choice."; return;;
  esac
  if [[ ${#newpass} -lt 8 ]]; then warn "Password is short (<8 chars) — not recommended."; fi
  read -r -p "  Apply new password now? [y/N]: " go
  [[ "$go" == "y" || "$go" == "Y" ]] || { info "Cancelled."; return; }
  write_secret "$PASS_FILE" "$newpass"
  systemctl restart nexdesk-gateway
  sleep 1
  if systemctl is-active --quiet nexdesk-gateway; then
    ok "Password updated and gateway restarted."
    info "Old sessions are now invalid — users must log in again."
  else
    fail "Gateway did not restart. Check: journalctl -u nexdesk-gateway -e"
  fi
}

change_webpath() {
  banner
  echo -e "  ${B}${CY}Change secret web path${R}"
  line
  echo -e "  Changing the web path moves your viewer to a new, unguessable URL."
  echo -e "  The old link stops working immediately."
  echo
  echo -e "  ${B}1)${R} Generate a new random path (recommended)"
  echo -e "  ${B}2)${R} Type my own path (letters/digits/dash only)"
  read -r -p "  Choose [1/2]: " m
  local newwp=""
  case "$m" in
    1) newwp="$(gen_hex 12)";;
    2)
      read -r -p "  New web path: " newwp
      [[ -n "$newwp" ]] || { fail "Path cannot be empty."; return; }
      [[ "$newwp" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { fail "Invalid path. Use 4-64 letters/digits/dash/underscore."; return; }
      ;;
    *) fail "Invalid choice."; return;;
  esac
  local ip="$(public_ip)"; [[ -n "$ip" ]] || ip="$(local_ips | head -1)"
  local _https="$(https_port_val)"
  echo
  echo -e "  New links will be:"
  echo -e "  ${WH}   http://${ip}:$(port_val)/${newwp}${R}"
  [[ -n "$_https" ]] && echo -e "  ${WH}   https://${ip}:${_https}/${newwp}${R}"
  read -r -p "  Apply now? [y/N]: " go
  [[ "$go" == "y" || "$go" == "Y" ]] || { info "Cancelled."; return; }
  write_secret "$WEBPATH_FILE" "$newwp"
  systemctl restart nexdesk-gateway
  sleep 1
  if systemctl is-active --quiet nexdesk-gateway; then
    ok "Web path updated and gateway restarted."
    echo
    echo -e "  ${B}${GR}Your new links:${R}"
    echo -e "  ${WH}   http://${ip}:$(port_val)/${newwp}${R}"
    [[ -n "$_https" ]] && echo -e "  ${WH}   https://${ip}:${_https}/${newwp}${R}"
    echo
    info "Open the new link and log in with your password. Old links are dead."
  else
    fail "Gateway did not restart. Check: journalctl -u nexdesk-gateway -e"
  fi
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
show_log() {
  echo
  echo -e "  ${B}${CY}Last lines of the gateway log${R}"
  line
  journalctl -u nexdesk-gateway -n 30 --no-pager 2>/dev/null | sed 's/^/  /' || true
  echo
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  banner
  echo -e "  ${RD}${B}Full uninstall${R}"
  line
  echo -e "  ${RD}This permanently removes:${R}"
  echo -e "   · the ${B}$NX_DIR${R} directory (code + all data)"
  echo -e "   · the service user 'nexdesk' and its home"
  echo -e "   · the 'nexdesk' admin command"
  echo -e "   · the 4 systemd services"
  echo
  echo -e "  ${YE}Your Chrome profile, sessions and downloads will be deleted.${R}"
  echo
  echo -e -n "  Type  ${B}UNINSTALL${R}  to confirm: "
  read -r c
  [[ "$c" == "UNINSTALL" ]] || { info "Cancelled — nothing was removed."; return; }
  echo -e -n "  Last chance. Type  ${B}UNINSTALL${R}  again: "
  read -r c2
  [[ "$c2" == "UNINSTALL" ]] || { info "Cancelled — nothing was removed."; return; }
  echo
  rm -f /usr/local/bin/nexdesk
  if [[ -x "$NX_DIR/uninstall.sh" ]]; then
    info "Running uninstaller..."
    "$NX_DIR/uninstall.sh"
  else
    warn "uninstall.sh missing — removing directory manually."
    systemctl stop nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway 2>/dev/null || true
    systemctl disable nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway 2>/dev/null || true
    rm -f /etc/systemd/system/nexdesk-{display,vnc,browser,gateway}.service
    systemctl daemon-reload
    rm -rf "$NX_DIR"
    userdel -r nexdesk 2>/dev/null || true
  fi
  echo
  echo -e "  ${GR}NexDesk has been removed from this server.${R}"
  echo -e "  You can delete the backup copy of this installer if you kept one."
  echo
  exit 0
}

# ---------------------------------------------------------------------------
# Update — pull the latest NexDesk release, keep link/password/profile
# ---------------------------------------------------------------------------
do_update() {
  banner_top
  echo -e "  ${B}${CY}Update NexDesk${R}"
  line
  echo -e "  Pulls the latest version from the NexDesk GitHub repository."
  echo -e "  Your secret link, password and browser profile are KEPT."
  echo
  echo -e "  ${YE}The NexDesk services restart briefly during the update.${R}"
  read -r -p "  Continue with the update now? [y/N]: " go
  [[ "$go" == "y" || "$go" == "Y" ]] || { info "Cancelled."; return; }
  echo
  info "Running the official updater (downloads the latest NexDesk)..."
  # Download the official installer first and check it really arrived. Piping a
  # failed download straight into bash runs an empty script that "succeeds",
  # which used to print "Update finished" even though nothing was updated.
  local upd="/tmp/nexdesk-update.sh"
  if ! curl -fsSL --max-time 60 -o "$upd" https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/master/install.sh; then
    fail "Could not download the updater (network error) — please retry."
    return
  fi
  if ! grep -q "one-command installer" "$upd"; then
    rm -f "$upd"
    fail "Downloaded updater looks invalid — please retry."
    return
  fi
  echo
  local rc=0
  bash "$upd" update || rc=$?
  rm -f "$upd"
  if [[ "$rc" == "0" ]]; then
    echo
    ok "Update finished."
  else
    echo
    fail "Update did not complete — see the messages above and the log under $NX_DIR/logs/."
  fi
  show_status
}

# ---------------------------------------------------------------------------
# Memory & performance panel
# ---------------------------------------------------------------------------
MEMDROP="/etc/systemd/system/nexdesk-browser.service.d/memory.conf"

# --- Hardware auto-detection (per-server tuning) ---------------------------
# Reads the real total RAM and CPU core count so every server is tuned to its
# own hardware instead of fixed values.
sys_ram_mib() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 2048; }
sys_cpu_cores() { nproc 2>/dev/null | tr -d '[:space:]' || echo 1; }

# Recommended hard RAM ceiling: leave the OS + NexDesk services a safe
# headroom, then give the rest to the browser. Extra-safe leaves ~half free.
ram_recommended() {
  local t
  t="$(sys_ram_mib)"
  # reserve = max(35% , 512 MiB); ceiling = total - reserve; never below 512
  awk -v t="$t" 'BEGIN{r=t*0.35; if(r<512)r=512; c=t-r; if(c<512)c=512; printf "%d", c}'
}
ram_extrasafe() {
  local t
  t="$(sys_ram_mib)"
  awk -v t="$t" 'BEGIN{r=t*0.50; if(r<512)r=512; c=t-r; if(c<512)c=512; printf "%d", c}'
}

# Best virtual-screen size for this hardware (higher-res looks sharper but a
# weak CPU/RAM server stays smoother on a smaller desktop).
res_recommended() {
  local cores ram
  cores="$(sys_cpu_cores)"; ram="$(sys_ram_mib)"
  if   [ "$ram" -ge 8000 ] && [ "$cores" -ge 6 ]; then echo "1920x1080";
  elif [ "$ram" -ge 4096 ] && [ "$cores" -ge 2 ]; then echo "1600x900";
  elif [ "$ram" -ge 2048 ] && [ "$cores" -ge 1 ]; then echo "1440x900";
  else echo "1280x720"; fi
}

sys_summary() {
  local ram cores
  ram="$(sys_ram_mib)"; cores="$(sys_cpu_cores)"
  echo -e "  ${B}Detected server:${R} ${ram} MiB RAM · ${cores} CPU core(s)"
  echo -e "  ${B}Recommended browser RAM ceiling:${R} $(ram_recommended) MiB"
  echo -e "  ${B}Recommended screen size:${R} $(res_recommended)"
}

budget_text() {
  if [ -f "$MEMDROP" ]; then
    local h m
    h="$(sed -n 's/^MemoryHigh=//p' "$MEMDROP")"
    m="$(sed -n 's/^MemoryMax=//p' "$MEMDROP")"
    echo "soft ${h} / hard ceiling ${m}"
  else
    echo "none (browser may use as much as free RAM allows)"
  fi
}

mem_show() {
  echo
  echo -e "  ${B}${CY}Live memory view${R}"
  line
  echo -e "  ${B}Memory:${R}"
  free -h | sed 's/^/    /'
  echo
  local pids="" pid rss tot=0 cnt=0
  pids="$(pgrep -x chrome 2>/dev/null || true)"
  for pid in $pids; do
    rss="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
    rss="${rss:-0}"; tot=$((tot + rss)); cnt=$((cnt + 1))
  done
  echo -e "  ${B}Chrome processes:${R} ${cnt}"
  local chrome_mem=""
  chrome_mem="$(systemctl show nexdesk-browser -p MemoryCurrent --value 2>/dev/null || true)"
  if [[ "$chrome_mem" =~ ^[0-9]+$ ]] && [ "$chrome_mem" -gt 0 ]; then
    echo -e "  ${B}NexDesk browser total RAM (cgroup):${R} $((chrome_mem/1048576)) MiB"
  else
    echo -e "  ${B}Combined RSS (may over-count shared pages):${R} $((tot/1024)) MiB"
  fi
  if [ "$cnt" -gt 0 ]; then
    echo
    echo -e "  ${B}Heaviest Chrome processes (RAM / process type):${R}"
    for pid in $pids; do
      rss="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
      echo "$((rss)) $pid"
    done | sort -rn | head -8 | while read -r rss pid; do
      tp="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -oE '\-\-type=[A-Za-z-]+' | head -1)" || true
      printf '    %7d MiB   %s\n' "$((rss/1024))" "${tp:-browser}"
    done
  fi
  echo
  echo -e "  ${B}Browser RAM ceiling:${R} $(budget_text)"
  line
}

mem_saver() {
  echo
  echo -e "  ${B}${CY}Memory Saver — free RAM from inactive tabs${R}"
  line
  echo -e "  When the server is under memory pressure Chrome already lets go of"
  echo -e "  inactive background tabs by itself. Setting a browser RAM ceiling"
  echo -e "  (option 3 in this panel) is what makes that happen early and safely."
  echo
  echo -e "  To make it even more eager, turn on Chrome's own Memory Saver once"
  echo -e "  (this is the switch Google recommends for saving RAM):"
  echo
  echo -e "   ${B}1)${R} in the NexDesk browser, open a new tab"
  echo -e "   ${B}2)${R} go to        ${WH}chrome://settings/performance${R}"
  echo -e "   ${B}3)${R} turn         ${B}Memory Saver${R}   ON"
  echo -e "   ${B}4)${R} optional: use 'Maximum' mode for the strongest savings"
  echo
  echo -e "  The setting is saved in your profile, so it survives restarts."
  line
}

budget_set() {
  echo
  local total rec safe
  total="$(sys_ram_mib)"; rec="$(ram_recommended)"; safe="$(ram_extrasafe)"
  echo -e "  ${B}Set a RAM ceiling for the whole NexDesk browser${R}"
  echo -e "  Current ceiling: $(budget_text)"
  echo
  sys_summary
  echo
  echo -e "  NexDesk reads how much RAM THIS server has, keeps a safe reserve"
  echo -e "  for the operating system, and caps the browser below that so RAM"
  echo -e "  can never fill up and lock the server."
  echo
  echo -e "  ${CY}1${R}  Recommended for this server   → hard ceiling ${B}${rec} MiB${R}"
  echo -e "  ${CY}2${R}  Extra safe (keep ~half free)  → hard ceiling ${B}${safe} MiB${R}"
  echo -e "  ${CY}3${R}  Custom value (MiB)"
  echo -e "  ${CY}4${R}  Remove the RAM ceiling"
  echo -e "  ${D}0${R}  Cancel"
  read -r -p "  Choose [1-4/0]: " m
  local v=""
  case "$m" in
    1) v="$rec";;
    2) v="$safe";;
    3) read -r -p "  Ceiling in MiB (>= 512): " v;;
    4) budget_clear; return;;
    0|'') info "Cancelled."; return;;
    *) fail "Invalid choice."; return;;
  esac
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 512 ]; then fail "Enter a number of MiB >= 512."; return; fi
  local soft=$(( v * 88 / 100 ))
  read -r -p "  Apply a hard ceiling of ${v} MiB now (restarts the browser)? [y/N]: " go
  [[ "$go" == "y" || "$go" == "Y" ]] || { info "Cancelled."; return; }
  mkdir -p /etc/systemd/system/nexdesk-browser.service.d
  printf '[Service]\nMemoryHigh=%dM\nMemoryMax=%dM\n' "$soft" "$v" > "$MEMDROP"
  systemctl daemon-reload
  systemctl restart nexdesk-browser
  sleep 1
  if systemctl is-active --quiet nexdesk-browser; then
    ok "Ceiling applied: soft ${soft}M / hard ceiling ${v}M."
  else
    fail "Browser did not restart after applying the ceiling."
  fi
}

budget_clear() {
  echo
  if [ -f "$MEMDROP" ]; then
    read -r -p "  Remove the RAM ceiling (restarts the browser)? [y/N]: " go
    [[ "$go" == "y" || "$go" == "Y" ]] || { info "Cancelled."; return; }
    rm -f "$MEMDROP"
    rmdir /etc/systemd/system/nexdesk-browser.service.d 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart nexdesk-browser
    sleep 1
    if systemctl is-active --quiet nexdesk-browser; then ok "Ceiling removed."; else fail "Browser did not restart."; fi
  else
    info "No RAM ceiling is currently set."
  fi
}

zram_status() {
  if swapon --show 2>/dev/null | grep -q '/dev/zram'; then
    echo -e "  ${GR}zram compressed swap: ACTIVE${R}"
    swapon --show 2>/dev/null | grep '/dev/zram' | sed 's/^/    /'
  else
    echo -e "  ${D}zram compressed swap: not active${R}"
  fi
}

zram_on() {
  echo
  if swapon --show 2>/dev/null | grep -q '/dev/zram'; then ok "zram is already active."; zram_status; return; fi
  local used=0
  if [ -x /usr/lib/systemd/system-generators/zram-generator ]; then
    printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
    systemctl daemon-reload > /dev/null 2>&1
    if systemctl start systemd-zram-setup@zram0.service 2>/dev/null; then used=1; ok "zram enabled (zram-generator)."; fi
  fi
  if [ "$used" -eq 0 ]; then
    if ! command -v zramswap > /dev/null 2>&1; then
      info "Installing zram-tools..."
      if ! apt-get install -y zram-tools > /dev/null 2>&1; then
        fail "Could not install zram-tools (no network / apt). Nothing changed."
        zram_status
        return
      fi
    fi
    printf 'ALGO=zstd\nPERCENT=50\nPRIORITY=100\n' > /etc/default/zramswap
    if systemctl enable --now zramswap 2>/dev/null || service zramswap start 2>/dev/null; then
      ok "zram enabled (zram-tools)."
    else
      warn "The zram service did not start cleanly — please check the log."
    fi
  fi
  echo; zram_status
}

zram_off() {
  echo
  if command -v zramswap > /dev/null 2>&1; then
    systemctl disable --now zramswap 2>/dev/null || service zramswap stop 2>/dev/null || true
  fi
  if [ -f /etc/systemd/zram-generator.conf ]; then
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    rm -f /etc/systemd/zram-generator.conf
    systemctl daemon-reload > /dev/null 2>&1
  fi
  for d in $(zramctl -l -n -o NAME 2>/dev/null || true); do
    swapoff "/dev/$d" 2>/dev/null || true
  done
  ok "zram swap disabled."
}

zram_menu() {
  banner_top
  echo -e "  ${B}${CY}Memory & performance > zram swap${R}"
  line
  zram_status
  echo
  echo -e "  ${CY}1${R}  Enable zram (compressed RAM swap)"
  echo -e "  ${CY}2${R}  Disable zram"
  echo -e "  ${D}0${R}  Back"
  read -r -p "  Choose [1/2/0]: " c
  case "$c" in
    1) zram_on;;
    2) zram_off;;
  esac
}

res_current() {
  local ov=/etc/systemd/system/nexdesk-display.service.d/screen.conf
  local src
  if [ -f "$ov" ]; then src="$ov"; else src=/etc/systemd/system/nexdesk-display.service; fi
  sed -nE 's#.*-screen 0 ([0-9]+x[0-9]+)x[0-9]+.*#\1#p' "$src" | head -1
}

# Restart display+vnc+browser together (they are coupled) and report state.
_res_start() {
  systemctl restart nexdesk-display
  systemctl restart nexdesk-vnc
  systemctl restart nexdesk-browser
  sleep 2
  local n=0
  for svc in nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway; do
    systemctl is-active --quiet "$svc" && n=$((n+1))
  done
  [ "$n" -eq 4 ] && ok "All services running at ${1}." || warn "Some services did not restart cleanly."
}

res_apply() { # $1 = WxH
  local W="${1%x*}" H="${1#*x}"
  local dunit=/etc/systemd/system/nexdesk-display.service
  local bunit=/etc/systemd/system/nexdesk-browser.service
  local dexec bexec nd nb
  dexec="$(sed -n 's/^ExecStart=//p' "$dunit" | head -1)"
  bexec="$(sed -n 's/^ExecStart=//p' "$bunit" | head -1)"
  if [ -z "$dexec" ] || [ -z "$bexec" ]; then fail "Could not read the service units."; return; fi
  nd="$(printf '%s\n' "$dexec" | sed -E "s/-screen 0 [0-9]+x[0-9]+x[0-9]+/-screen 0 ${W}x${H}x24/")"
  nb="$(printf '%s\n' "$bexec" | sed -E "s/--window-size=[0-9]+x[0-9]+/--window-size=${W}x${H}/")"
  if ! printf '%s\n' "$nd" | grep -q -- "-screen 0 ${W}x${H}"; then
    fail "Could not prepare the new screen size."; return
  fi
  local ddir=/etc/systemd/system/nexdesk-display.service.d
  local bdir=/etc/systemd/system/nexdesk-browser.service.d
  mkdir -p "$ddir" "$bdir"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$nd" > "$ddir/screen.conf"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$nb" > "$bdir/screen.conf"
  systemctl daemon-reload
  echo
  info "Applying ${W}x${H} and restarting the display services..."
  _res_start "${W}x${H}"
}

res_reset() {
  rm -f /etc/systemd/system/nexdesk-display.service.d/screen.conf
  rmdir /etc/systemd/system/nexdesk-display.service.d 2>/dev/null || true
  rm -f /etc/systemd/system/nexdesk-browser.service.d/screen.conf
  systemctl daemon-reload
  echo
  info "Restoring the original factory screen size..."
  _res_start "$(res_current || echo original)"
}

quality_menu() {
  local cur rec cores ram
  cur="$(res_current || echo unknown)"
  rec="$(res_recommended)"
  cores="$(sys_cpu_cores)"; ram="$(sys_ram_mib)"
  echo
  echo -e "  ${B}${CY}Graphics quality — screen size${R}"
  line
  echo -e "  Detected: ${ram} MiB RAM · ${cores} CPU core(s)"
  echo -e "  Current screen: ${B}${cur:-unknown}${R}   Recommended: ${B}${rec}${R}"
  echo
  echo -e "  A smaller screen is smoother on low RAM/CPU servers; a larger one"
  echo -e "  is sharper but heavier. Changing it restarts the desktop briefly."
  echo
  echo -e "  ${CY}1${R}  Apply recommended (${rec}) for this server"
  echo -e "  ${CY}2${R}  1280x720   — lightest / smoothest"
  echo -e "  ${CY}3${R}  1440x900   — balanced"
  echo -e "  ${CY}4${R}  1600x900   — sharper (needs 2+ cores, 4GiB+)"
  echo -e "  ${CY}5${R}  1920x1080  — largest (needs 6+ cores, 8GiB+)"
  echo -e "  ${CY}6${R}  Restore the original factory size"
  echo -e "  ${D}0${R}  Back"
  read -r -p "  Choose: " c
  case "$c" in
    1) want="$rec";;
    2) want="1280x720";;
    3) want="1440x900";;
    4) want="1600x900";;
    5) want="1920x1080";;
    6) echo; read -r -p "  Restore the factory screen size now? [y/N]: " g
       [[ "$g" == y || "$g" == Y ]] && res_reset; return;;
    0|'') info "Back."; return;;
    *) fail "Invalid choice."; return;;
  esac
  if [ "${want:-}" = "$cur" ]; then info "Already ${cur} — nothing to change."; return; fi
  echo
  read -r -p "  Change the screen size to ${want} now? [y/N]: " g
  [[ "$g" == y || "$g" == Y ]] || { info "Cancelled."; return; }
  res_apply "$want"
}

mem_panel() {
  local c=""
  while true; do
    banner_top
    echo -e "  ${B}${CY}Memory & performance${R}"
    line
    sys_summary
    echo
    echo -e "  ${CY}1${R}  Live memory view + heaviest Chrome processes"
    echo -e "  ${CY}2${R}  Memory Saver — free RAM from inactive tabs"
    echo -e "  ${CY}3${R}  Set a RAM ceiling for the whole browser"
    echo -e "  ${CY}4${R}  Remove the browser RAM ceiling"
    echo -e "  ${CY}5${R}  zram — compressed swap to smooth memory spikes"
    echo -e "  ${CY}6${R}  Graphics quality — screen size (tuned to this server)"
    echo -e "  ${D}0${R}  Back to main menu"
    echo
    read -r -p "  Choose: " c
    case "$c" in
      1) mem_show;;
      2) mem_saver;;
      3) budget_set;;
      4) budget_clear;;
      5) zram_menu;;
      6) quality_menu;;
      0) return;;
      *) echo -e "  ${RD}Invalid choice: $c${R}"; sleep 1; continue;;
    esac
    echo
    read -r -p "  Press Enter to return to Memory & performance... " _
  done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
menu() {
  banner
  echo -e "  ${B}${WH}What would you like to do?${R}"
  echo
  echo -e "  ${CY}1${R}  Show connection info (link + password)"
  echo -e "  ${CY}2${R}  Show service status"
  echo -e "  ${CY}3${R}  Restart all services"
  echo
  echo -e "  ${CY}4${R}  Change password"
  echo -e "  ${CY}5${R}  Change secret web path"
  echo
  echo -e "  ${CY}6${R}  View recent gateway log"
  echo -e "  ${CY}7${R}  Memory & performance (control RAM usage)"
  echo -e "  ${CY}8${R}  Update NexDesk (keep link/password)"
  echo -e "  ${RD}9${R}  Full uninstall (remove NexDesk)"
  echo -e "  ${D}0${R}  Exit"
  echo
}

loop() {
  while true; do
    menu
    read -r -p "  Choose: " c
    case "$c" in
      1) show_info;;
      2) banner_top; show_status;;
      3) banner_top; restart_all;;
      4) change_password;;
      5) change_webpath;;
      6) banner_top; show_log;;
      7) mem_panel;;
      8) do_update;;
      9) do_uninstall;;
      0|q|Q|exit) echo -e "  ${D}Bye.${R}"; exit 0;;
      *) echo -e "  ${RD}Invalid choice: $c${R}"; sleep 1;;
    esac
    echo
    echo -e "  ${D}Press Enter to return to the menu...${R}"
    read -r _
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
need_root

# Cheap path checks so errors are friendly.
[[ -d "$NX_DIR" ]]            || { fail "Install directory not found: $NX_DIR"; exit 1; }
[[ -f "$PASS_FILE" ]]         || warn "Password file missing: $PASS_FILE"
[[ -f "$WEBPATH_FILE" ]]      || warn "Web path file missing: $WEBPATH_FILE"

case "${1:-}" in
  info)   show_info;;
  status) banner_top; show_status;;
  -h|--help|help)
    grep -E '^#' "$0" | head -20; exit 0;;
  "")
    loop;;
  *)
    echo -e "  ${RD}Unknown option: $1${R}"
    echo -e "  Usage: nexdesk   |   nexdesk info   |   nexdesk status"
    exit 1;;
esac
