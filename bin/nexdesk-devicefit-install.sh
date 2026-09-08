#!/usr/bin/env bash
# NexDesk device-fit installer
# Makes THIS server behave identically to a device-fit-capable gateway: the
# virtual display + browser are launched through controllers that read
# /opt/nexdesk/state/resolution.txt, so a connecting device can reshape the
# desktop to its own screen and fill it edge-to-edge (no letterbox bars).
#
# Run once, as root, on each gateway host:
#     sudo /opt/nexdesk/bin/nexdesk-devicefit-install.sh
# Idempotent and safe to re-run. Backups of replaced unit files are kept.
set -euo pipefail

BIN=/opt/nexdesk/bin
DIR=/opt/nexdesk
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/5] ensuring launcher + resize scripts in $BIN"
mkdir -p "$BIN"
for f in nexdesk-display.sh nexdesk-browser-launch.sh nexdesk-resize.sh fit-window.sh; do
  if [ ! -x "$BIN/$f" ]; then
    if [ -x "$SELF_DIR/$f" ]; then install -m0755 "$SELF_DIR/$f" "$BIN/$f";
    else echo "missing required script: $BIN/$f (expected it next to this installer or already installed)"; exit 1; fi
  fi
done

echo "==> [2/5] preparing state dir + nexdesk user"
mkdir -p "$DIR/state"
if ! id nexdesk >/dev/null 2>&1; then useradd -r -M -s /bin/bash nexdesk 2>/dev/null || true; fi
chown -R nexdesk:nexdesk "$DIR/state" 2>/dev/null || true

echo "==> [3/5] installing systemd units (with backups)"
TS="$(date +%Y%m%d-%H%M%S)"
for u in nexdesk-display.service nexdesk-browser.service; do
  if [ -f "/etc/systemd/system/$u" ] && [ ! -f "/etc/systemd/system/$u.bak-devicefit-$TS" ]; then
    cp -a "/etc/systemd/system/$u" "/etc/systemd/system/$u.bak-devicefit-$TS"
  fi
done

cat > /etc/systemd/system/nexdesk-display.service <<'UNIT'
[Unit]
Description=NexDesk virtual display (Xvfb)
After=systemd-user-sessions.service

[Service]
Type=simple
Nice=-10
ExecStart=/opt/nexdesk/bin/nexdesk-display.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/nexdesk-browser.service <<'UNIT'
[Unit]
Description=NexDesk persistent browser (Chromium)
After=nexdesk-display.service nexdesk-audio.service
Requires=nexdesk-display.service

[Service]
Type=simple
User=nexdesk
Environment=DISPLAY=:99
Environment=PULSE_SERVER=unix:/run/nexdesk-audio/pulse/native
Environment=PULSE_RUNTIME_PATH=/run/nexdesk-audio/pulse
ExecStart=/opt/nexdesk/bin/nexdesk-browser-launch.sh
ExecStartPost=/opt/nexdesk/bin/fit-window.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

echo "==> [4/5] installing passwordless sudo for the gateway"
cat > /etc/sudoers.d/nexdesk-resize <<'SUDO'
Defaults:nexdesk !requiretty
nexdesk ALL=(root) NOPASSWD: /opt/nexdesk/bin/nexdesk-resize.sh
nexdesk ALL=(root) NOPASSWD: /usr/bin/systemd-run
SUDO
chmod 0440 /etc/sudoers.d/nexdesk-resize
visudo -cf /etc/sudoers.d/nexdesk-resize >/dev/null

echo "==> [5/5] reloading units and restarting display/browser"
systemctl daemon-reload
systemctl enable nexdesk-display.service nexdesk-browser.service >/dev/null 2>&1 || true
systemctl restart nexdesk-display.service nexdesk-browser.service

echo "==> device-fit installed. Restart nexdesk-gateway.service to pick it up:"
echo "    systemctl restart nexdesk-gateway.service"
