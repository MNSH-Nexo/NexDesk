#!/usr/bin/env bash
# Force the Chrome/Chromium window to fill the Xvfb display (no WM present).
command -v xdotool >/dev/null 2>&1 || exit 0
for i in $(seq 1 30); do
  WID="$(xdotool search --onlyvisible --class chrome 2>/dev/null | head -1)"
  [ -z "$WID" ] && WID="$(xdotool search --onlyvisible --class Chromium 2>/dev/null | head -1)"
  [ -n "$WID" ] && break
  sleep 1
done
[ -n "$WID" ] || exit 0
xdotool windowsize "$WID" 100% 100% >/dev/null 2>&1 || true
xdotool windowmove "$WID" 0 0 >/dev/null 2>&1 || true
