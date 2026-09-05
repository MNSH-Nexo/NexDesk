#!/usr/bin/env bash
#
# NexDesk — one-command installer for a self-hosted virtual browser.
#
# Detects the OS (Debian/Ubuntu), installs the lightweight WebVNC engine
# (Chromium + Xvfb + x11vnc + noVNC) plus the NexDesk gateway, creates an
# isolated service user, generates a secret URL/password/port, starts the
# stack as systemd services, and finally prints the owner's personal link.
#
# Usage:
#   sudo ./install.sh                 # defaults: /opt/nexdesk, port 8087
#   sudo ./install.sh --port 8443 --dir /opt/nexdesk
#
# Env overrides:
#   NX_PORT    listening port (default 8087)
#   NX_DIR     install directory (default /opt/nexdesk)
#   NX_USER    service account (default nexdesk)
#   NX_SWAP    'auto' (ask to create 4G swap if none found) or 'off' (never touch swap)
#   NX_SWAP_SIZE   swap-file size to create when asked (default 4G)
#   NX_SWAPFILE    swap-file path (default /swapfile)
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
# Swap readiness
#    NexDesk runs several Chrome processes; a little swap avoids the kernel
#    OOM-killing them under load. If no swap is active we ask the operator
#    (y/N) before creating a swap file (default 4G). Respects NX_SWAP=off.
# ---------------------------------------------------------------------------
maybe_swap() {
  [[ "${NX_SWAP:-auto}" != "off" ]] || { warn "Swap setup skipped (NX_SWAP=off)."; return 0; }

  # Already have an active swap device/file?
  if command -v swapon >/dev/null 2>&1 && swapon --show --noheadings 2>/dev/null | grep -q .; then
    ok "Active swap detected — skipping swap setup."
    return 0
  fi

  local SZ="${NX_SWAP_SIZE:-4G}" FILE="${NX_SWAPFILE:-/swapfile}" ans cnt=4096
  case "${SZ^^}" in
    *G) cnt=$(( ${SZ%G} * 1024 ));;
    *M) cnt=${SZ%M};;
  esac

  warn "No active swap was found on this server."
  warn "NexDesk runs several Chrome processes; without swap, heavy use can"
  warn "exhaust RAM and cause processes to be killed by the kernel (OOM)."
  echo
  read -r -p "  Create a ${SZ} swap file at ${FILE} now? [y/N]: " ans || true
  case "${ans,,}" in
    y|yes)
      info "Creating swap file ${FILE} (${SZ}) — this may take a moment..."
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "$SZ" "$FILE" 2>/dev/null \
          || { rm -f "$FILE"; dd if=/dev/zero of="$FILE" bs=1M count="$cnt" status=none 2>/dev/null; }
      else
        dd if=/dev/zero of="$FILE" bs=1M count="$cnt" status=none 2>/dev/null
      fi
      chmod 600 "$FILE"
      if mkswap "$FILE" >/dev/null 2>&1 && swapon "$FILE" 2>/dev/null; then
        grep -q "^${FILE}[[:space:]]" /etc/fstab 2>/dev/null \
          || printf '%s none swap sw 0 0\n' "$FILE" >> /etc/fstab
        ok "Swap enabled (${SZ}) — active now and restored after reboot."
        free -m 2>/dev/null | sed -n '1,2p' | sed 's/^/    /' || true
      else
        rm -f "$FILE"
        warn "Could not enable swap; continuing without it."
      fi
      ;;
    *)
      warn "Skipped. If Chrome is later killed for low memory, add swap, e.g.:"
      warn "  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
      ;;
  esac
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
