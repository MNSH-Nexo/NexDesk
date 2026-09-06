#!/usr/bin/env bash
# NexDesk audio daemon launcher.
# Runs a private PulseAudio server (as the nexdesk user) exposing a null sink
# "nxsink". The virtual Chrome outputs its sound to nxsink; the gateway then
# reads nxsink.monitor with parec and streams it to visitors over a WebSocket.
set -euo pipefail
RUNTIME="/run/nexdesk-audio"
export XDG_RUNTIME_DIR="$RUNTIME"
export PULSE_RUNTIME_PATH="$RUNTIME/pulse"
mkdir -p "$RUNTIME" "$RUNTIME/pulse"

# PulseAudio refuses to run as root.
if [ "$(id -u)" -eq 0 ]; then
  echo "nexdesk-audio must not run as root" >&2
  exit 1
fi

/usr/bin/pulseaudio -n \
  --daemonize=no \
  --exit-idle-time=-1 \
  --log-target=stderr \
  --load="module-native-protocol-unix auth-anonymous=1" \
  --load="module-always-sink" \
  --load="module-null-sink sink_name=nxsink sink_properties=device.description=NexDesk_Virtual_Sound" \
  &
PULSE_PID=$!
trap "kill $PULSE_PID 2>/dev/null || true" EXIT

# Wait until the daemon answers, then make nxsink the default sink so Chrome
# automatically routes its sound there.
for _ in $(seq 1 40); do
  if pactl info >/dev/null 2>&1; then break; fi
  sleep 0.25
done
pactl set-default-sink nxsink 2>/dev/null || true

wait "$PULSE_PID"
