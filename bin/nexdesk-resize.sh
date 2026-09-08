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

# ---- Serialize: only one desktop rebuild at a time -----------------------
# The gateway restarts itself during a rebuild, so the gateway's in-process
# concurrency guard is lost across that restart. A quick enlarge-then-shrink can
# therefore start two rebuilds at once; two rebuilds fighting over the display
# service make the services flap and systemd rate-limits them into "stopped
# until a manual start" (the long gateway outage). flock makes back-to-back
# requests apply strictly one at a time. If a prior rebuild is still running we
# wait up to 45s (never stack forever) then give up cleanly.
mkdir -p /opt/nexdesk/state
exec 9> /opt/nexdesk/state/resize.lock
flock -w 45 9 || { echo "resize-busy" >&2; exit 3; }

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

# Drop any restart rate-limit a flapping unit accumulated, so the stack can
# never be auto-stuck in "stopped until a manual start".
systemctl reset-failed nexdesk-browser.service nexdesk-vnc.service nexdesk-gateway.service nexdesk-display.service 2>/dev/null || true

systemctl stop nexdesk-browser.service 2>/dev/null || true
systemctl stop nexdesk-vnc.service 2>/dev/null || true
systemctl stop nexdesk-gateway.service 2>/dev/null || true
systemctl restart nexdesk-display.service
for i in $(seq 1 30); do systemctl is-active nexdesk-display.service >/dev/null 2>&1 && break; sleep 1; done
# gateway Requires=nexdesk-vnc, so systemd brings vnc active before it launches
# the gateway -- no long synchronous wait that could hold the stack down.
systemctl start nexdesk-vnc.service 2>/dev/null || true
systemctl start nexdesk-gateway.service 2>/dev/null || true
systemctl start nexdesk-browser.service 2>/dev/null || true
exit 0
