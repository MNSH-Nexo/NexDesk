#!/usr/bin/env bash
set -uo pipefail
R_FILE="/opt/nexdesk/state/resolution.txt"
RES="1280x720"
if [ -r "$R_FILE" ]; then
  R="$(tr -dc 0-9x < "$R_FILE")"
  case "$R" in *x*) ;; *) R="" ;; esac
  if [ -n "$R" ]; then
    W="${R%x*}"; H="${R#*x}"
    if [[ "$W" =~ ^[0-9]+$ ]] && [[ "$H" =~ ^[0-9]+$ ]] && [ "$W" -ge 480 ] && [ "$W" -le 2600 ] && [ "$H" -ge 360 ] && [ "$H" -le 1800 ]; then RES="$R"; fi
  fi
fi
export DISPLAY="${NEXDESK_DISPLAY:-:99}"
if [ "browser" = display ]; then
  exec /usr/bin/Xvfb "$DISPLAY" -screen 0 "${RES}x24" -nolisten tcp
else
  exec /usr/bin/google-chrome --user-data-dir=/opt/nexdesk/.chrome --window-size=${RES} --window-position=0,0 --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --no-first-run --no-default-browser-check --force-device-scale-factor=1 --remote-debugging-port=9223 --remote-debugging-address=127.0.0.1 --remote-allow-origins=* --force-prefers-reduced-motion "file:///opt/nexdesk/src/core/gateway/welcome.html"
fi
