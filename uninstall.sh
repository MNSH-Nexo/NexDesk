#!/usr/bin/env bash
#
# NexDesk — clean uninstaller.
#
# Stops and removes the four NexDesk systemd services, deletes the units,
# and removes the install directory (including secrets). Optionally removes
# the service account.
#
# Usage:
#   sudo ./uninstall.sh                 # defaults: /opt/nexdesk, user nexdesk
#   sudo ./uninstall.sh --dir /opt/nexdesk --keep-user
#
set -euo pipefail

C_RESET="\e[0m"; C_GRN="\e[32m"; C_CYN="\e[36m"; C_RED="\e[31m"; C_YEL="\e[33m"
info() { echo -e "${C_CYN}  [i]${C_RESET} $*"; }
ok()   { echo -e "${C_GRN}  [ok]${C_RESET} $*"; }
die()  { echo -e "${C_RED}  [x] $*${C_RESET}"; exit 1; }

NX_DIR="/opt/nexdesk"
NX_USER="nexdesk"
KEEP_USER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)       NX_DIR="$2"; shift 2;;
    --keep-user) KEEP_USER=1; shift;;
    *) die "Unknown option: $1";;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo ./uninstall.sh"

info "Stopping NexDesk services..."
for svc in nexdesk-gateway nexdesk-browser nexdesk-vnc nexdesk-display; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
ok "Services stopped and disabled."

info "Removing unit files..."
rm -f /etc/systemd/system/nexdesk-{display,vnc,browser,gateway}.service
systemctl daemon-reload
ok "Unit files removed."

info "Removing 'nexdesk' admin command..."
rm -f /usr/local/bin/nexdesk
ok "Admin command removed."

info "Removing install directory $NX_DIR ..."
rm -rf "$NX_DIR"
ok "Install directory removed."

if [[ "$KEEP_USER" -eq 0 ]]; then
  if id "$NX_USER" >/dev/null 2>&1; then
    info "Removing service account '$NX_USER' and its home..."
    userdel -r "$NX_USER" 2>/dev/null || true
    ok "Service account removed."
  fi
fi

echo
echo "==============================================================================="
echo -e "  ${C_GRN}NexDesk has been fully uninstalled.${C_RESET}"
echo "==============================================================================="
