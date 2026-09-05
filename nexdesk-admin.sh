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
  read -r -p "  Type  ${B}UNINSTALL${R}  to confirm: " c
  [[ "$c" == "UNINSTALL" ]] || { info "Cancelled — nothing was removed."; return; }
  read -r -p "  Last chance. Type  ${B}UNINSTALL${R}  again: " c2
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
  echo -e "  ${RD}7${R}  Full uninstall (remove NexDesk)"
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
      7) do_uninstall;;
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
