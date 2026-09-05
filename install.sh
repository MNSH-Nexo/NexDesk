#!/usr/bin/env bash
#
# NexDesk — one-command installer for a self-hosted virtual browser.
#
# Detects the OS (Debian/Ubuntu), installs the lightweight WebVNC engine
# (Chromium + Xvfb + x11vnc + noVNC) plus the NexDesk gateway, creates an
# isolated service user, generates a secret URL/password/port, starts the
# stack as systemd services, and finally prints the owner's personal link.
#
# One-command install from anywhere (no repo needed on the machine):
#   bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/main/install.sh)
#
# The same command also updates (re-run) or removes NexDesk:
#   bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/main/install.sh) update
#   bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/main/install.sh) uninstall
#
# Or run it from a checkout directly:
#   ./install.sh                      # defaults: /opt/nexdesk, port 8087
#   ./install.sh --port 8443 --dir /opt/nexdesk
#
# Optional flags:  --port PORT   --dir DIR   --user USER
# Optional env:    NX_PORT  NX_DIR  NX_USER  NX_SWAP(auto|off)  NX_SWAPFILE  NX_SRC_URL
#
# Running non-interactively (e.g. curl ... | sudo bash) skips the questions and
# uses safe defaults; running interactively asks a couple of simple questions.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Colours / helpers
# ---------------------------------------------------------------------------
C_RESET="\e[0m"; C_BOLD="\e[1m"; C_GRN="\e[32m"; C_CYN="\e[36m"; C_YEL="\e[33m"; C_RED="\e[31m"
info()  { echo -e "${C_CYN}  [i]${C_RESET} $*"; }
ok()    { echo -e "${C_GRN}  [ok]${C_RESET} $*"; }
warn()  { echo -e "${C_YEL}  [!]${C_RESET} $*"; }
die()   { echo -e "${C_RED}  [x] $*${C_RESET}"; exit 1; }

# ---------------------------------------------------------------------------
# One-command bootstrap
#    NexDesk is built to run straight from a pipe, in a single command:
#
#      bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/main/install.sh)
#
#    When executed that way only *this* file is downloaded, so if the rest of
#    the source tree is not sitting next to us we fetch it and hand over to the
#    real installer (auto-elevating to root with sudo when needed).
#
#    The same public file doubles as an updater and uninstaller:
#      .../install.sh              -> install (or update) NexDesk
#      .../install.sh update       -> pull the latest code, keep link + password
#      .../install.sh uninstall    -> fully remove NexDesk from this server
#
#    When run from a full checkout (./install.sh) these branches are skipped
#    and the normal installer below runs directly.
# ---------------------------------------------------------------------------
_SRC_URL="${NX_SRC_URL:-https://codeload.github.com/MNSH-Nexo/NexDesk/tar.gz/refs/heads/main}"
_DIR_OF() { cd "$(dirname "$1")" 2>/dev/null && pwd || echo "."; }
SCRIPT_DIR="$(_DIR_OF "${BASH_SOURCE[0]:-$0}")"
HAS_SOURCE=0
[[ -f "$SCRIPT_DIR/src/core/gateway/server.js" ]] && HAS_SOURCE=1

# Fetch the full source so a fetched-pipe install always has every file.
# Echoes the absolute path of the freshly downloaded repo directory.
_fetch_source() {
  local work dir
  work="$(mktemp -d "${TMPDIR:-/tmp}/nexdesk.XXXXXX")"
  info "Fetching NexDesk source (a moment)..." >&2
  curl -fsSL "$_SRC_URL" | tar -xz -C "$work"
  dir="$work/NexDesk-main"
  [[ -f "$dir/install.sh" ]] || die "Downloaded source was incomplete — please retry the command."
  printf '%s' "$dir"
}

# Run a script as root (auto-elevate with sudo; interactive when needed).
_run_root() { # $1 = script path, then args
  local scr="$1"; shift
  if [[ "$(id -u)" -eq 0 ]]; then
    bash "$scr" "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "Root access required. Install 'sudo' or run as root."
    info "Elevating to root with sudo..."
    sudo -E bash "$scr" "$@"
  fi
}

_cmd="${1:-install}"

# --- uninstall -------------------------------------------------------------
if [[ "$_cmd" == "uninstall" || "$_cmd" == "--uninstall" ]]; then
  shift || true
  if [[ "$HAS_SOURCE" -eq 1 ]] && [[ -f "$SCRIPT_DIR/uninstall.sh" ]]; then
    _run_root "$SCRIPT_DIR/uninstall.sh" "$@"
  else
    _DIR="$(_fetch_source)"
    _run_root "$_DIR/uninstall.sh" "$@"
    rm -rf "$(dirname "$_DIR")"
  fi
  exit $?
fi

# --- install / update ------------------------------------------------------
if [[ "$_cmd" == "update" || "$_cmd" == "--update" ]]; then shift || true; fi
if [[ "$_cmd" == "install" || "$_cmd" == "--install" ]]; then shift || true; fi

if [[ "$HAS_SOURCE" -eq 0 ]]; then
  # We were fetched alone over the pipe: bring down the source and run it.
  _DIR="$(_fetch_source)"
  _run_root "$_DIR/install.sh" "$@"
  _rc=$?
  rm -rf "$(dirname "$_DIR")"
  exit $_rc
fi

# Running from a checkout as a normal user: re-run ourselves as root.
if [[ "$(id -u)" -ne 0 ]]; then
  _run_root "$SCRIPT_DIR/install.sh" "$@"
  exit $?
fi

# ---------------------------------------------------------------------------
# Swap readiness
#    NexDesk runs several Chrome processes; a little swap avoids the kernel
#    OOM-killing them under load. If no swap is active we let the operator
#    choose how much to create (1/2/3/4G, a custom size, or skip).
#    Respects NX_SWAP=off and NX_SWAPFILE.
# ---------------------------------------------------------------------------
maybe_swap() {
  [[ "${NX_SWAP:-auto}" != "off" ]] || { warn "Swap setup skipped (NX_SWAP=off)."; return 0; }

  # Already have an active swap device/file?
  if command -v swapon >/dev/null 2>&1 && swapon --show --noheadings 2>/dev/null | grep -q .; then
    ok "Active swap detected — skipping swap setup."
    return 0
  fi

  local FILE="${NX_SWAPFILE:-/swapfile}" DIR ANS="" SIZE="" CNT=0 FREE=""
  DIR="$(dirname "$FILE")"
  FREE="$(df -h -P "$DIR" 2>/dev/null | awk 'NR==2{print $4}')"

  warn "No active swap was found on this server."
  warn "NexDesk runs several Chrome processes; without swap, heavy use can be"
  warn "killed by the kernel (OOM).  Free space on $DIR: ${FREE:-unknown}"
  echo

  # Choose a size interactively. EOF (non-interactive) defaults to skipping.
  while :; do
    echo "  Choose how much swap to create, or skip:"
    echo "     1)  1G         2)  2G"
    echo "     3)  3G         4)  4G"
    echo "     5)  Custom size   (e.g. 512M or 2G)"
    echo "     0)  Skip — leave swap off"
    read -r -p "  Your choice [0-5]: " ANS || true
    case "${ANS,,}" in
      ""|0|n|no|skip)
        warn "Skipped. If Chrome is later killed for low memory, add swap, e.g.:"
        warn "  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
        return 0
        ;;
      1) SIZE="1G"; break;;
      2) SIZE="2G"; break;;
      3) SIZE="3G"; break;;
      4) SIZE="4G"; break;;
      5|c|custom)
        read -r -p "  Size (like 512M or 2G): " SIZE || true
        if [[ "$SIZE" =~ ^[0-9]+[GgMm]$ ]]; then break
        else warn "Invalid size '$SIZE' — use e.g. 512M or 2G."; SIZE=""; fi
        ;;
      *) warn "Invalid choice '$ANS' — please pick a number 0-5.";;
    esac
  done

  case "${SIZE^^}" in
    *G) CNT=$(( ${SIZE%G} * 1024 ));;
    *M) CNT=${SIZE%M};;
  esac

  info "Creating swap file ${FILE} (${SIZE}) — this may take a moment..."
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "$SIZE" "$FILE" 2>/dev/null \
      || { rm -f "$FILE"; dd if=/dev/zero of="$FILE" bs=1M count="$CNT" status=none 2>/dev/null; }
  else
    dd if=/dev/zero of="$FILE" bs=1M count="$CNT" status=none 2>/dev/null
  fi
  chmod 600 "$FILE"
  if mkswap "$FILE" >/dev/null 2>&1 && swapon "$FILE" 2>/dev/null; then
    grep -q "^${FILE}[[:space:]]" /etc/fstab 2>/dev/null \
      || printf '%s none swap sw 0 0\n' "$FILE" >> /etc/fstab
    ok "Swap enabled (${SIZE}) — active now and restored after reboot."
    free -m 2>/dev/null | sed -n '1,2p' | sed 's/^/    /' || true
  else
    rm -f "$FILE"
    warn "Could not enable swap (not enough space?) — continuing without it."
  fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
NX_PORT="${NX_PORT:-8087}"
NX_DIR="${NX_DIR:-/opt/nexdesk}"
NX_USER="${NX_USER:-nexdesk}"
DISPLAY_NUM=99
VNC_PORT=5900
BROWSER_RES="1440x880"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     NX_PORT="$2"; shift 2;;
    --dir)      NX_DIR="$2"; shift 2;;
    --user)     NX_USER="$2"; shift 2;;
    --help|-h)  grep -E '^#' "$0" | head -40; exit 0;;
    *)          die "Unknown option: $1 (see --help)";;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo ./install.sh"
command -v apt-get >/dev/null 2>&1 || die "This installer supports Debian/Ubuntu only (apt-get not found)."
export DEBIAN_FRONTEND=noninteractive

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$REPO_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$REPO_DIR")"

info "NexDesk installer"
info "  Target dir : $NX_DIR"
info "  Web port   : $NX_PORT"
info "  User       : $NX_USER"
echo

# A couple of simple questions when running interactively; non-interactive
# runs (pipes) skip straight ahead and use the defaults above.
if [[ -t 0 ]] && [[ "${NX_YES:-0}" != "1" ]]; then
  echo -e "  NexDesk is about to be installed on ${C_BOLD}this${C_RESET} server."
  echo -e "  Change the web port here or press Enter to keep ${C_GRN}${NX_PORT}${C_RESET}:"
  read -r -p "  Port [${NX_PORT}]: " _p || true
  if [[ -n "${_p:-}" ]]; then
    case "$_p" in
      ''|*[!0-9]*) warn "Ignoring non-numeric port '$_p' — keeping ${NX_PORT}.";;
      *) NX_PORT="$_p";;
    esac
  fi
  read -r -p "  Start the installation now? [Y/n]: " _go || true
  case "${_go:-y}" in
    y|Y|yes|YES|Yes|"") : ;;
    *) die "Aborted — nothing was installed.";;
  esac
  unset _go _p
  echo
fi

# ---------------------------------------------------------------------------
# Memory / swap readiness check (ask before doing heavy work)
# ---------------------------------------------------------------------------
maybe_swap

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
info "Updating package index and installing core dependencies..."
apt-get update -qq
apt-get install -y -qq xvfb x11vnc novnc websockify curl openssl xauth >/dev/null
ok "Core packages installed."

info "Installing browser runtime libraries (best-effort across distro versions)..."
# Names differ between releases (e.g. libasound2 on <24.04 vs libasound2t64 on 24.04),
# so we install what is available and never let a missing optional lib abort install.
apt-get install -y -qq fonts-liberation libnss3 libnspr4 libatk1.0-0 \
  libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
  libxfixes3 libxrandr2 libgbm1 >/dev/null || true
apt-get install -y -qq libasound2 libasound2t64 >/dev/null 2>&1 || true
ok "Runtime libraries handled."

# ---------------------------------------------------------------------------
# 2. Browser engine (Google Chrome preferred, Chromium fallback)
# ---------------------------------------------------------------------------
BROWSER_BIN=""
if command -v google-chrome >/dev/null 2>&1; then
  BROWSER_BIN="$(command -v google-chrome)"
  ok "Found Google Chrome at $BROWSER_BIN"
else
  info "Installing Google Chrome (stable, .deb)..."
  if ! command -v google-chrome-stable >/dev/null 2>&1; then
    curl -fsSL -o /tmp/chrome.deb \
      "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
      && apt-get install -y -qq /tmp/chrome.deb >/dev/null 2>&1 || true
    rm -f /tmp/chrome.deb
  fi
  if command -v google-chrome-stable >/dev/null 2>&1; then
    BROWSER_BIN="$(command -v google-chrome-stable)"
  elif command -v chromium >/dev/null 2>&1; then
    BROWSER_BIN="$(command -v chromium)"
    warn "Using Chromium (snap/chromium may need sandbox adjustments)."
  else
    apt-get install -y -qq chromium-browser >/dev/null 2>&1 && BROWSER_BIN="$(command -v chromium-browser || true)" || true
  fi
  [[ -n "$BROWSER_BIN" ]] || die "No browser engine available. Install Google Chrome and rerun."
  ok "Browser engine: $BROWSER_BIN"
fi

# ---------------------------------------------------------------------------
# 3. Service user + directory layout
# ---------------------------------------------------------------------------
info "Creating isolated service user '$NX_USER' and directories..."
if ! id "$NX_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin --comment "NexDesk service user" "$NX_USER"
fi
mkdir -p "$NX_DIR"/{src,config,logs}
install -d -o "$NX_USER" -g "$NX_USER" "$NX_DIR/config" "$NX_DIR/logs" "$NX_DIR/.chrome"

# Copy gateway source (unless we are already installing from inside the target,
# in which case the source is already in place).
if [[ "$(readlink -f "$REPO_ROOT")" == "$(readlink -f "$NX_DIR")" ]]; then
  ok "Installing from within the target directory — source already present."
else
  [[ -d "$REPO_ROOT/src/core/gateway" ]] || die "Gateway source not found under $REPO_ROOT/src/core/gateway"
  install -d -o "$NX_USER" -g "$NX_USER" "$NX_DIR/src/core/gateway"
  cp -a "$REPO_ROOT/src/core/gateway/." "$NX_DIR/src/core/gateway/"
  rm -rf "$NX_DIR/src/core/gateway/node_modules"
fi
chown -R "$NX_USER":"$NX_USER" "$NX_DIR/src"
ok "Directories and source in place at $NX_DIR."

# Install the NexDesk admin-menu script (repo top-level) into the target.
if [[ -f "$REPO_DIR/nexdesk-admin.sh" && "$REPO_DIR/nexdesk-admin.sh" != "$NX_DIR/nexdesk-admin.sh" ]]; then
  install -m 0755 -o root -g root "$REPO_DIR/nexdesk-admin.sh" "$NX_DIR/nexdesk-admin.sh"
  ok "Admin menu script installed at $NX_DIR/nexdesk-admin.sh."
fi

# ---------------------------------------------------------------------------
# 4. Secrets
#    On first install we generate a fresh webpath/password/hmac secret.
#    Re-running install.sh preserves existing secrets so your URL stays valid.
# ---------------------------------------------------------------------------
mkdir -p "$NX_DIR/config"
WEBPATH=""; PASSWORD=""; HMAC_SECRET=""
if [[ -s "$NX_DIR/config/webpath.txt" && -s "$NX_DIR/config/pass.txt" && -s "$NX_DIR/.secret" ]]; then
  WEBPATH="$(<"$NX_DIR/config/webpath.txt")"
  PASSWORD="$(<"$NX_DIR/config/pass.txt")"
  HMAC_SECRET="$(<"$NX_DIR/.secret")"
  ok "Existing secrets detected — keeping your current link/password."
else
  info "Generating fresh secrets and owner link..."
  WEBPATH="$(openssl rand -hex 12)"
  PASSWORD="$(openssl rand -base64 9 | tr '+/' 'Aa')"
  HMAC_SECRET="$(openssl rand -hex 16)"
  umask 077
  printf '%s\n' "$WEBPATH"    > "$NX_DIR/config/webpath.txt"
  printf '%s\n' "$PASSWORD"   > "$NX_DIR/config/pass.txt"
  printf '%s\n' "$HMAC_SECRET"> "$NX_DIR/.secret"
  chown "$NX_USER":"$NX_USER" "$NX_DIR/.secret" "$NX_DIR/config"/* "$NX_DIR/config"
  ok "Secrets written (owner-only read)."
fi

# ---------------------------------------------------------------------------
# 5. Gateway npm deps
# ---------------------------------------------------------------------------
info "Installing gateway dependencies (express + ws)..."
(cd "$NX_DIR/src/core/gateway" && npm install --no-audit --no-fund --production >/dev/null)
ok "Gateway dependencies installed."

# ---------------------------------------------------------------------------
# 6. Systemd units
# ---------------------------------------------------------------------------
info "Writing systemd service units..."
BROWSER_OPTS="--disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --no-first-run --no-default-browser-check --start-maximized"
cat > /etc/systemd/system/nexdesk-display.service <<UNIT
[Unit]
Description=NexDesk virtual display (Xvfb)
After=systemd-user-sessions.service
[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :${DISPLAY_NUM} -screen 0 1440x900x24 -nolisten tcp
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/nexdesk-vnc.service <<UNIT
[Unit]
Description=NexDesk VNC server (x11vnc)
After=nexdesk-display.service
Requires=nexdesk-display.service
[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display :${DISPLAY_NUM} -nopw -shared -forever -repeat -localhost -rfbport ${VNC_PORT}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/nexdesk-browser.service <<UNIT
[Unit]
Description=NexDesk persistent browser (Chromium)
After=nexdesk-display.service
Requires=nexdesk-display.service
[Service]
Type=simple
User=${NX_USER}
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=${BROWSER_BIN} --user-data-dir=${NX_DIR}/.chrome --window-size=${BROWSER_RES} --window-position=0,0 ${BROWSER_OPTS} about:blank
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/nexdesk-gateway.service <<UNIT
[Unit]
Description=NexDesk web gateway (login + noVNC + VNC bridge)
After=network.target nexdesk-vnc.service
Requires=nexdesk-vnc.service
[Service]
Type=simple
User=${NX_USER}
WorkingDirectory=${NX_DIR}/src/core/gateway
Environment=NODE_ENV=production
Environment=PORT=${NX_PORT}
Environment=VNC_HOST=127.0.0.1
Environment=VNC_PORT=${VNC_PORT}
Environment=NOVNC_DIR=/usr/share/novnc
Environment=PASS_FILE=${NX_DIR}/config/pass.txt
Environment=WEBPATH_FILE=${NX_DIR}/config/webpath.txt
Environment=SECRET_FILE=${NX_DIR}/.secret
Environment=VIEWER_FILE=${NX_DIR}/src/core/gateway/viewer.html
ExecStart=/usr/bin/node ${NX_DIR}/src/core/gateway/server.js
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
for svc in nexdesk-display nexdesk-vnc nexdesk-browser nexdesk-gateway; do
  systemctl enable -q "$svc"
  systemctl restart "$svc"
done
ok "Services started (display, vnc, browser, gateway)."

# Register the `nexdesk` admin-menu command (idempotent).
if [[ -f "$NX_DIR/nexdesk-admin.sh" ]]; then
  ln -sf "$NX_DIR/nexdesk-admin.sh" /usr/local/bin/nexdesk
  chmod 0755 "$NX_DIR/nexdesk-admin.sh"
  ok "Admin menu registered — type 'nexdesk' (as root)."
fi

# ---------------------------------------------------------------------------
# 7. Wait for readiness and print the owner link
# ---------------------------------------------------------------------------
info "Waiting for the gateway to accept connections..."
# The service intentionally answers 404 on root, so we probe the TCP port
# instead of expecting an HTTP 200.
for i in $(seq 1 20); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${NX_PORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 1
done

PUBIP="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo '<your-server-ip>')"
clear 2>/dev/null || true
echo
echo "==============================================================================="
echo -e "  ${C_BOLD}NexDesk is ready 🎉  Your personal virtual browser${C_RESET}"
echo "==============================================================================="
echo
echo -e "  ${C_BOLD}Personal link:${C_RESET}"
echo -e "  ${C_GRN}  http://${PUBIP}:${NX_PORT}/${WEBPATH}${C_RESET}"
echo
echo -e "  ${C_BOLD}Password:${C_RESET}   ${C_CYN}${PASSWORD}${C_RESET}"
echo
echo "  Keep this link + password secret. It is your only key to this session."
echo "  Root / unknown URLs return 404 so the service stays hidden."
echo
echo "  Manage:  systemctl status nexdesk-{gateway,browser,vnc,display}"
echo "  Admin menu:  sudo nexdesk      (change password/web path, info, uninstall)"
echo "  Uninstall: sudo $NX_DIR/uninstall.sh  (when available)"
echo "==============================================================================="
