# NexDesk — Self-Hosted Virtual Cloud Browser

**NexDesk** turns any Debian/Ubuntu server into your own private "browser in the cloud".
Install it once, and you get a **persistent, full-screen virtual Chrome** that you open from
any device through your browser, guarded by a secret link and a password.

Unlike browser-in-the-cloud SaaS, NexDesk is **self-hosted**: you own the server, the data,
the session, and the key. The browser profile (tabs, logins, downloads) is stored on your
machine and **survives restarts**, so it works like a real desktop you can reach anywhere.

---

## Features

- **Private by design** — the real UI lives under a randomly generated *secret path*; the
  root and every unknown URL return a plain `404` so the service stays invisible to scanners.
- **Single password login** — protected by a salted HMAC check and a signed, `HttpOnly`
  session cookie; the password comparison is constant-time (immune to timing attacks).
- **Persistent Chrome profile** — your tabs, logins and settings are saved on the server and
  reload on every connection.
- **Full-screen noVNC viewer** — an immersive, auto-hiding remote desktop inside the browser,
  with zoom/fit toggles and a dark frame, ready for both desktop and mobile.
- **Clipboard sync** — copy/paste text from your machine into the virtual desktop (`Ctrl+V`
  inside the remote Chrome).
- **Real keyboard language & Caps-Lock handling** — character keysyms (e.g. Persian layouts)
  are forwarded to the virtual X display, and the guest **Caps Lock is never forwarded** to the
  remote (case is controlled by your own keyboard). Stuck modifier keys are cleared when a
  session connects.
- **Live resource meter** — the top bar shows real **CPU %** and **RAM used/total** with a
  colour gauge (green → yellow → red), reading NexDesk's own processes plus host totals.
- **Adaptive connection quality** — a top-bar control (**Auto / High / Balanced / Low**) lets you
  pick the remote-desktop quality. On **Auto**, NexDesk continuously measures the real delivery
  rate and round-trip latency (shown live, e.g. `Q6 · 800 kbps · 60 ms`) and adjusts JPEG/colour
  quality on the fly — dropping it on slow links and restoring it when the link recovers, all
  without reconnecting.
- **Self-healing connection** — if the link drops or the session is closed (even by a momentary
  internet blip), the viewer **reconnects automatically** with a growing back-off and keeps
  retrying on its own; no manual `Retry` needed in normal cases.
- **Robust bridge** — the gateway fully tears down every dead/half-open session (its own ping
  watchdog drops unresponsive clients and every exit path frees the VNC socket), so a dropped
  visitor can never wedge the single x11vnc connection and block the next viewer.
- **Memory Saver on by default** — the virtual Chrome runs with Chrome's *Memory Saver*
  (tab-discarding) enabled as the default, so background tabs stop eating the server's limited RAM.
- **English-locale Chrome** — the profile is forced to `en-US` so pages do not flip to the
  server region's language.
- **Real Chrome sandbox** — deliberately *not* launched with `--no-sandbox`.
- **Swap safety net** — during install, if the server has no active swap the installer
  lets you choose how much swap to create (1/2/3/4G, a custom size, or skip).
- **A clean installer and uninstaller** — one command brings the whole stack up as `systemd`
  services; one command tears it down completely.

---

## Architecture

NexDesk is a small stack of four cooperating components, managed by four `systemd` units.

| Service | Role |
| --- | --- |
| `nexdesk-display` | Starts **Xvfb**, a headless virtual display on `:99`. |
| `nexdesk-vnc` | Runs **x11vnc**, which exposes the virtual display as a VNC server bound to **localhost:5900**. |
| `nexdesk-browser` | Launches the persistent **Chrome** session on that display and pins it to the full virtual screen. |
| `nexdesk-gateway` | The **Node.js / Express** gateway on port **8087** — the only public entry point. |

Everything reaches the user only through the gateway:

```
                          public network
                               |
                    +----------v-----------+
                    |   NexDesk gateway    |   Express on 0.0.0.0:8087
                    |  (login · viewer ·   |   secret path /<secret>
                    |   noVNC · clipboard  |   WS<->VNC bridge
                    |   · /api/stats       |   + adaptive-quality
                    |   · /api/link)       |   + dead-session cleanup
                    +----------+-----------+
                       HTTP/WS  |  127.0.0.1
              +-----------------v------------------+
              |  noVNC  <-- WebSocket -->  x11vnc   |  VNC server
              |                    (localhost:5900) |  on display :99
              +-------------------+-----------------+
                                  |
                         +--------v--------+
                         |  Xvfb   :99     |  headless virtual display
                         |   +-- Chrome    |  persistent profile (~/.chrome)
                         +-----------------+
```

**Request flow for a visitor:**

1. Browser hits `http://<server>:8087/<secret-path>/` → gateway asks for the password.
2. A correct password issues an `HttpOnly` session cookie (`ndauth`) valid for 30 days.
3. The gateway serves the noVNC viewer UI plus the noVNC static assets.
4. The viewer opens a **WebSocket** to `/<secret-path>/vnc`; the gateway authenticates the
   cookie, then **bridges** the WebSocket to the local VNC TCP port on `127.0.0.1:5900`.
5. On connect, the gateway resets the virtual keyboard to a clean state (Caps off, no stuck
   modifiers).
6. Key and pointer events and framebuffer updates stream over that bridge in real time.

The VNC server only ever listens on **localhost** — it is never exposed directly to the
network; the gateway is the single, authenticated entry point.

---

## Installation

**Requirements**

- Debian or Ubuntu server (systemd, `root` or `sudo`), ~2 GB RAM or more recommended.
- A public IP and/or an open or mapped port (default **8087**).

**Quick start**

```bash
sudo ./install.sh
```

Done. The installer prints your **personal link** and **password** at the end — keep them secret.

> During install, if the server has no active swap the installer lets you pick how much swap
> to create (1/2/3/4G, or a custom size like 512M/2G) — or skip. NexDesk runs several Chrome
> processes, and swap prevents out-of-memory kills; pick a size that fits your free disk space.
> To never touch swap, run with `NX_SWAP=off`.

**Options**

```bash
sudo ./install.sh --port 8443 --dir /opt/nexdesk     # custom port + directory
```

Environment overrides (equivalent to the flags):

| Variable | Default | Meaning |
| --- | --- | --- |
| `NX_PORT` | `8087` | Public listening port |
| `NX_DIR` | `/opt/nexdesk` | Install directory |
| `NX_USER` | `nexdesk` | Isolated service account |

The installer detects the OS, installs the engine (Chromium/Xvfb/x11vnc/noVNC) and the
gateway dependencies, creates an **isolated service user**, generates the secret path,
password and signing secret, wires up the four `systemd` units, starts the stack, and prints
your personal link.

> The personal link already contains the secret path, and the gateway only responds under it —
> so sharing the full link, together with the password, is what grants access.

---

## Uninstall

```bash
sudo ./uninstall.sh               # stop services, remove units + directory + service user
sudo ./uninstall.sh --keep-user   # keep the 'nexdesk' account
```

---

## Project layout

```
NexDesk/
├── install.sh                 # one-command installer
├── uninstall.sh               # clean teardown
├── bin/
│   └── nexdesk-browser.sh     # Chrome launcher (language, profile, window sizing)
├── src/core/gateway/
│   ├── server.js              # gateway: auth, viewer, noVNC, WS<->VNC, clipboard, stats
│   ├── viewer.html            # full-screen noVNC UI (top bar, resource meter)
│   └── package.json           # express + ws
└── systemd/
    ├── nexdesk-display.service
    ├── nexdesk-vnc.service
    ├── nexdesk-browser.service
    └── nexdesk-gateway.service
```

Runtime secrets and data are generated under the install directory and are **never tracked by
git** (see Security):

```
/opt/nexdesk/
├── config/pass.txt        # login password
├── config/webpath.txt     # secret URL path
├── .secret                # HMAC signing secret
├── .chrome/               # live Chrome profile (sessions, logins, downloads)
└── logs/                  # service logs
```

---

## Configuration (environment variables)

**Gateway** (`server.js`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8087` | Listening port |
| `VNC_HOST` | `127.0.0.1` | VNC host the gateway bridges to |
| `VNC_PORT` | `5900` | VNC port |
| `NOVNC_DIR` | `/usr/share/novnc` | noVNC static files |
| `PASS_FILE` | `/opt/nexdesk/config/pass.txt` | Password file |
| `WEBPATH_FILE` | `/opt/nexdesk/config/webpath.txt` | Secret path file |
| `SECRET_FILE` | `/opt/nexdesk/.secret` | Signing secret file |
| `VIEWER_FILE` | `.../viewer.html` | Viewer HTML |
| `NEXDESK_DISPLAY` | `:99` | Virtual display for clipboard/keyboard |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

**Browser** (`nexdesk-browser.sh`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXDESK_DISPLAY` | `:99` | Display Chrome opens on |
| `NEXDESK_CHROME` | `/usr/bin/google-chrome` | Chrome binary |
| `NEXDESK_PROFILE` | `/opt/nexdesk/.chrome` | Persistent profile |
| `NEXDESK_RES_X` | `1440` | Virtual resolution width |
| `NEXDESK_RES_Y` | `900` | Virtual resolution height |
| `NEXDESK_START_URL` | `about:blank` | Page Chrome opens with |

---

## HTTP API (all under the secret path)

| Route | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/login` | GET | no | Show the (Persian, RTL) login form |
| `/login` | POST | no | Verify password, set `ndauth` cookie |
| `/` | GET | cookie | Serve the full-screen viewer |
| `/logout` | GET | — | Clear the cookie, back to login |
| `/vnc` | WS | cookie | WebSocket to VNC bridge |
| `/novnc/*` | GET | cookie | noVNC static assets |
| `/clipboard` | POST | cookie | Write text into the remote clipboard |
| `/api/stats` | GET | cookie | Host + per-process CPU/RAM (used by the top bar) |
| `/api/link` | GET | cookie | Live delivered throughput (kbps) + round-trip (ms) measured by the gateway (drives Auto quality) |

Everything **outside** the secret path — including the bare root — returns `404 Not found`.

---

## Tuning the connection (bandwidth / latency)

NexDesk adapts to slow networks so the virtual desktop stays usable without burning bandwidth.

- **Quality selector (top bar):** `Auto`, `High`, `Balanced` or `Low`. This controls the noVNC
  JPEG quality and compression level, which x11vnc applies **live** — the change takes effect in
  the current session, there is no reconnect.
- **Auto mode:** every 2 seconds the gateway reports the real data actually delivered to your
  browser (`/api/link`) together with the round-trip time. The viewer smooths those values and,
  when the link struggles, drops quality immediately to keep motion fluid and data low; when the
  link has headroom it restores crispness. A small live read-out (e.g. `Q6 · 800 kbps · 60 ms`)
  shows the current quality, throughput and latency.
- **Auto-reconnect:** if the connection drops for any reason while the tab is open, the viewer
  reconnects on its own (1.5s → 8s back-off, up to 5 tries), including when you return to a tab
  that was in the background during the drop. Only after the automatic attempts are exhausted do
  you see a manual `Retry`.
- **Dead-session cleanup:** the gateway pings each client and drops any that stop responding, and
  tears the session down cleanly on every error/close path — so a visitor who vanishes never
  leaves a half-open connection that could block the next viewer.

### Memory Saver on the virtual Chrome

Chrome's *Memory Saver* (which discards background tabs to free RAM) is enabled as the **default**
on the persistent virtual browser. It is applied as a **recommended** policy so an operator can
still toggle it inside the virtual Chrome at `chrome://settings/performance`:

```json
# /etc/opt/chrome/policies/managed/nexdesk-performance.json
[ { "HighEfficiencyModeEnabled": { "Value": true, "level": "recommended" } } ]
```

On an already-installed server, create that file and `sudo systemctl restart nexdesk-browser`.
It is safe on a memory-constrained host and has no effect while you are only using the active tab.

---

## Security model

- **Secret-by-obscurity done properly:** the real app lives at an unguessable random path;
  every other request (including root) returns a generic `404`. No login page is exposed at `/`.
- **Password hashing:** salted **HMAC-SHA256** keyed by a server-side secret; the password is
  never compared in plaintext and checks are **constant-time**.
- **Signed cookie:** the `ndauth` value is an HMAC of the password under the same secret,
  marked `HttpOnly` and scoped to its path, with a 30-day expiry.
- **Local-only VNC:** x11vnc binds to `127.0.0.1`, never to a public interface — there is no
  second port to attack.
- **Real Chrome sandbox** is left enabled (no `--no-sandbox`).
- **Single low-privilege user** runs the services; secrets and the live profile are owned by it.
- **git hygiene:** `.secret`, `config/pass.txt`, `config/webpath.txt`, the `.chrome/` profile,
  logs and lock/`node_modules` files are all gitignored so secrets can never be pushed.

---

## Managing the service

```bash
# Status of the whole stack
systemctl status 'nexdesk-*'

# Restart one piece (e.g. the gateway after a config change)
sudo systemctl restart nexdesk-gateway

# Follow logs
journalctl -u nexdesk-gateway -f
```

---

## Roadmap

- [ ] Optional multi-user accounts with per-user profiles
- [ ] Download forwarding from the remote to the visitor's machine
- [ ] Automatic HTTPS (Caddy / Traefik) documentation
- [ ] Docker Compose packaging for ephemeral setups
