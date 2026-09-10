#!/usr/bin/env bash
#
# NexDesk - keep the server clock in the country this machine actually sits in.
#
# Chrome reports the host's time zone to every website it visits, so a server
# hosted in one country while its clock says UTC is an easy mismatch for
# anti-bot checks to spot. This helper asks a location service where the box is
# and aligns the system time zone with it.
#
# It is deliberately conservative: it does nothing when the zone already
# matches its location, and it never guesses - if the lookup fails, or the
# resolved zone is not one this system knows, the current setting is kept.
#
# Usage:
#   nexdesk-sync-tz.sh                        auto-detect the location and apply
#   NX_TZ=Europe/Berlin nexdesk-sync-tz.sh    force a specific zone
#   NX_TZ=off nexdesk-sync-tz.sh              do nothing
#
# Always exits 0, so it is safe to call from the installer and from systemd.
set -uo pipefail

log() { printf '[nexdesk-tz] %s\n' "$*"; }

WANT_TZ="${NX_TZ:-auto}"
if [[ "$WANT_TZ" == "off" || "$WANT_TZ" == "0" ]]; then
  log "disabled (NX_TZ=$WANT_TZ) - time zone left as-is."
  exit 0
fi

if ! command -v timedatectl >/dev/null 2>&1; then
  log "timedatectl is unavailable - nothing to do."
  exit 0
fi

CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

if [[ "$WANT_TZ" == "auto" ]]; then
  WANT_TZ=""
  if command -v curl >/dev/null 2>&1; then
    for url in "https://ipinfo.io/json" "https://ipwho.is/" "https://ipapi.co/json/"; do
      body="$(curl -fsS --max-time 8 "$url" 2>/dev/null || true)"
      if [[ -z "$body" ]]; then
        continue
      fi
      # Accepts {"timezone":"Europe/Helsinki"} and {"timezone":{"id":"..."}}.
      candidate="$(printf '%s' "$body" | sed -n 's/.*"timezone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      if [[ -z "$candidate" ]]; then
        candidate="$(printf '%s' "$body" | sed -n 's/.*"timezone"[^}]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      fi
      # A real zone looks like Area/City; anything else is not trustworthy.
      if [[ "$candidate" == */* ]]; then
        WANT_TZ="$candidate"
        log "location detected via ${url#https://}: $WANT_TZ"
        break
      fi
    done
  else
    log "curl is unavailable - cannot look up this machine's location."
  fi
fi

if [[ -z "$WANT_TZ" || "$WANT_TZ" != */* ]]; then
  log "could not tell where this server is - keeping ${CURRENT_TZ:-unknown}."
  exit 0
fi

if [[ ! -e "/usr/share/zoneinfo/$WANT_TZ" ]]; then
  log "time zone '$WANT_TZ' is not installed on this system - keeping ${CURRENT_TZ:-unknown}."
  exit 0
fi

if [[ "$WANT_TZ" == "$CURRENT_TZ" ]]; then
  log "already correct ($WANT_TZ)."
  exit 0
fi

if timedatectl set-timezone "$WANT_TZ" 2>/dev/null; then
  log "time zone set to $WANT_TZ (was ${CURRENT_TZ:-unknown})."
else
  log "could not set the time zone to $WANT_TZ - keeping ${CURRENT_TZ:-unknown}."
fi
exit 0
