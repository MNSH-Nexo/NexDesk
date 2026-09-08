#!/usr/bin/env bash
# NexDesk resize controller (run as root via sudo). usage: nexdesk-resize.sh WxH
# Rebuilds the shared desktop to fill the requesting device (no black bars).
# Before every rebuild it re-wires the Xvfb display service to the
# resolution-aware launcher (nexdesk-display.sh), so even a gateway host whose
# display service an update reset to a fixed size (screen.conf / Xvfb 1280x720)
# still resizes to fill each device, exactly like the reference server.
set -uo pipefail
R="${1:-}"
case "$R" in *x*) ;; *) echo "bad-size" >&2; exit 2;; esac
W="${R%x*}"; H="${R#*x}"
if ! [[ "$W" =~ ^[0-9]+$ ]] || ! [[ "$H" =~ ^[0-9]+$ ]]; then echo "bad-size" >&2; exit 2; fi
if [ "$W" -lt 480 ] || [ "$W" -gt 2600 ] || [ "$H" -lt 360 ] || [ "$H" -gt 1800 ]; then echo "out-of-range" >&2; exit 2; fi
mkdir -p /opt/nexdesk/state
printf "%s" "$R" > /opt/nexdesk/state/resolution.txt
chown nexdesk:nexdesk /opt/nexdesk/state/resolution.txt
chmod 644 /opt/nexdesk/state/resolution.txt

# Ensure the display service runs through the resolution-aware controller.
# zz- sorts last among drop-ins so it wins over any fixed-size drop-in an update
# wrote; the reset idiom (empty ExecStart then the value) keeps only one command.
LAUNCHER=/opt/nexdesk/bin/nexdesk-display.sh
if [ -x "$LAUNCHER" ]; then
  DDIR=/etc/systemd/system/nexdesk-display.service.d
  mkdir -p "$DDIR"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$LAUNCHER" > "$DDIR/zz-nexdesk-devicefit.conf"
  systemctl daemon-reload
fi

systemctl stop nexdesk-browser.service 2>/dev/null || true
systemctl stop nexdesk-vnc.service 2>/dev/null || true
systemctl stop nexdesk-gateway.service 2>/dev/null || true
systemctl restart nexdesk-display.service
for i in $(seq 1 40); do systemctl is-active nexdesk-display.service >/dev/null 2>&1 && break; sleep 1; done
systemctl start nexdesk-vnc.service 2>/dev/null || true
for i in $(seq 1 40); do systemctl is-active nexdesk-vnc.service >/dev/null 2>&1 && break; sleep 1; done
systemctl start nexdesk-gateway.service 2>/dev/null || true
systemctl start nexdesk-browser.service 2>/dev/null || true
exit 0
