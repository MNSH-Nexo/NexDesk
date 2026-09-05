#!/usr/bin/env bash
# NexDesk browser launcher: starts the persistent Chrome session, forces an
# English UI/content language, and (since there is no window manager to honour
# --start-maximized) resizes the Chrome window to fill the whole virtual display.
set -euo pipefail

export DISPLAY="${NEXDESK_DISPLAY:-:99}"
export LANG=en_US.UTF-8
export LANGUAGE=en
export LC_ALL=en_US.UTF-8
CHROME_BIN="${NEXDESK_CHROME:-/usr/bin/google-chrome}"
PROFILE="${NEXDESK_PROFILE:-/opt/nexdesk/.chrome}"
RES_X="${NEXDESK_RES_X:-1440}"
RES_Y="${NEXDESK_RES_Y:-900}"
START_URL="${NEXDESK_START_URL:-about:blank}"

# Sanitise/seed the profile's language so Chrome does not pick the server
# region's locale (e.g. Arabic). We only touch the 'intl' keys we own.
PREFS="$PROFILE/Default/Preferences"
if [ -f "$PREFS" ]; then
  python3 - "$PREFS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
intl = d.setdefault("intl", {})
intl["accept_languages"] = "en-US,en"
intl["selected_languages"] = "en-US,en"
intl["app_locale"] = "en-US"
# Drop Chrome's per-region country/language hints so web pages pick English.
prof = d.setdefault("profile", {})
if "content_settings" in d:
    d["content_settings"].pop("pref_version", None)
d.setdefault("browser", {}).pop("locale_control", None)
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
fi

# Ensure the profile is writable by the service user.
chown -R nexdesk:nexdesk "$PROFILE" 2>/dev/null || true

# Launch Chrome. --no-sandbox is intentionally NOT used (real sandbox is on).
"$CHROME_BIN" \
  --user-data-dir="$PROFILE" \
  --lang=en-US \
  --accept-lang=en-US,en \
  --window-size=${RES_X}x${RES_Y} \
  --window-position=0,0 \
  --force-device-scale-factor=1 \
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble \
  "$START_URL" &
CHROME_PID=$!

# No WM is running, so --start-maximized is ignored. Wait for the main window
# to appear, then pin it to the full virtual display.
for i in $(seq 1 60); do
  MAIN=$(xdotool search --onlyvisible --class "Google-chrome" 2>/dev/null | head -1 || true)
  if [ -n "$MAIN" ]; then
    xdotool windowsize "$MAIN" ${RES_X} ${RES_Y} 2>/dev/null || true
    xdotool windowmove "$MAIN" 0 0 2>/dev/null || true
    xdotool windowactivate "$MAIN" 2>/dev/null || true
    break
  fi
  sleep 0.5
done

wait "$CHROME_PID"
