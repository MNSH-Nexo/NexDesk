<p align="center">
  <img src="assets/nexdesk-logo.png" alt="NexDesk logo" width="180">
</p>

<h1 align="center">NexDesk</h1>
<p align="center"><strong>Self-Hosted Virtual Cloud Browser</strong></p>
<p align="center">
  Your own private, always-on Chrome in the cloud — reachable from any device,
  guarded by a secret link and a password. Install once, connect from anywhere.
</p>

<p align="center">
  Debian / Ubuntu &nbsp;·&nbsp; systemd &nbsp;·&nbsp; Node.js &nbsp;·&nbsp; Chrome &nbsp;·&nbsp; noVNC &nbsp;·&nbsp; VNC
</p>

---

## Contents

- [Why NexDesk](#why-nexdesk)
- [Key capabilities](#key-capabilities)
- [How it works](#how-it-works)
- [Technology stack](#technology-stack)
- [Installation](#installation)
- [Uninstall](#uninstall)
- [First connection](#first-connection)
- [Mobile input modes](#mobile-input-modes)
- [Project layout](#project-layout)
- [Configuration](#configuration)
- [HTTP API](#http-api)
- [Network tuning](#network-tuning)
- [Security model](#security-model)
- [Managing the service](#managing-the-service)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why NexDesk

Most "browser in the cloud" services are a subscription: your browsing lives on
someone else's servers, is reachable through someone else's doors, and your
sessions, logins and data sit in a place you do not control.

NexDesk turns any Debian or Ubuntu server into your **own** cloud browser. It
runs a real, persistent, full-screen Chrome on that machine, and lets you open it
from any device through a normal web page. Because it is self-hosted, you own the
server, the session, the data and the key.

- The **profile is persistent** — tabs, logins and downloads are saved on your
  server and survive restarts, so it behaves like a real desktop you can reach
  anywhere, not a disposable sandbox.
- Everything reaches you through a **single, authenticated gateway** — no VNC
  ports are ever exposed to the network.
- It is **private by design** — the interface lives under an unguessable secret
  path, and every other URL returns a plain `404`, so the service stays invisible
  to scanners.

NexDesk is a small, auditable stack of five cooperating services with one
command to install and one to remove — nothing opaque, nothing cloud-locked.

---

## Key capabilities

- **Private by design** — the real UI lives under a randomly generated secret
  path; the root and every unknown URL return a plain `404`, so the service stays
  invisible to scanners.
- **Single password login** — protected by a salted HMAC check and a signed,
  `HttpOnly` session cookie; the password comparison is constant-time and immune
  to timing attacks.
- **Persistent Chrome profile** — tabs, logins and settings are stored on the
  server and reload on every connection.
- **Full-screen noVNC viewer** — an immersive remote desktop inside your browser,
  with zoom/fit toggles and a dark frame, ready for desktop and mobile.
- **Near-real-time sound** — the virtual Chrome's audio is routed through a local
  PulseAudio null sink and streamed to the visitor over a WebSocket, with a short
  capture buffer for low latency.
- **Real keyboard language handling** — character keysyms (for example Persian
  layouts) are forwarded to the virtual display; the guest Caps Lock is never
  forwarded, and stuck modifier keys are cleared on every connection.
- **Clipboard sync** — copy and paste text between your machine and the virtual
  desktop.
- **Mobile on-screen keyboard** — touch users get English and Persian layouts
  (with a symbols layer, ZWNJ / half-space, Tab / Esc and a hold-to-repeat
  Backspace). It overlays the viewer only and never appears on the remote screen.
- **Mobile-optimized viewer** — auto-hiding top bar, fit-to-width by default,
  double-tap or a floating pill to toggle 1:1 zoom with drag-to-pan, and a layout
  that keeps the field you type in visible. In landscape the controls become a
  slim always-visible strip above the screen.
- **Mobile Mouse / trackpad mode** — an optional precise-pointer layer for
  touch devices (a floating **Mouse** pill). Drag moves a visible pointer, tap
  clicks, **press-and-hold then drag selects text**, long hold / two-finger tap
  right-clicks, and a **natural two-finger scroll** (drag up scrolls down).
  When off, the classic Touch behaviour is untouched, and on a desktop device
  the mode never appears.
- **Live resource meter** — the top bar shows real CPU percent and RAM
  used/total with a colour gauge (green to yellow to red).
- **Adaptive connection quality** — an Auto / High / Balanced / Low control. In
  Auto mode NexDesk continuously measures delivered throughput and round-trip
  latency and adjusts the JPEG quality live, dropping it on slow links and
  restoring it as bandwidth recovers — without reconnecting.
- **Self-healing connection** — if the link drops, the viewer reconnects on its
  own with a growing back-off and keeps retrying; no manual action in normal
  cases.
- **Stale-cache-proof viewer** — if a cached viewer page points at an outdated
  noVNC asset path, the page detects it and silently reloads itself once with a
  fresh copy.
- **Robust bridge** — the gateway tears down every dead or half-open session
  (a ping watchdog and every exit path free the VNC socket), so a vanished visitor
  can never wedge the single VNC connection and block the next viewer.
- **Memory Saver on by default** — the virtual Chrome discards background tabs to
  save the server's limited RAM.
- **English-locale Chrome** — the profile is pinned to `en-US` so pages do not
  flip to the server region's language.
- **Real Chrome sandbox** — deliberately not launched with `--no-sandbox`.
- **Swap safety net** — during install, a server without active swap is offered
  1/2/3/4G (or a custom size) of swap to avoid out-of-memory kills.
- **Clean installer and uninstaller** — one command brings the whole stack up as
  `systemd` services; one command removes it completely.

---

## How it works

NexDesk is a small stack of five cooperating components, each managed by its own
`systemd` unit.

| Service | Role |
| --- | --- |
| `nexdesk-display` | Starts **Xvfb**, a headless virtual display on `:99`. |
| `nexdesk-vnc` | Runs **x11vnc**, exposing the display as a VNC server bound to **localhost:5900**. |
| `nexdesk-browser` | Launches the persistent **Chrome** session on that display, pinned to the full virtual screen. |
| `nexdesk-audio` | Runs a private **PulseAudio** daemon with a null sink so the virtual Chrome has sound. |
| `nexdesk-gateway` | The **Node.js / Express** gateway on port **8087** — the only public entry point. |

Every visitor reaches the system only through the gateway:

```
                          public network
                               |
                    +----------v-----------+
                    |   NexDesk gateway    |   Express on 0.0.0.0:8087
                    |  (login · viewer ·   |   secret path /<secret>
                    |   noVNC · clipboard  |   WS<->VNC bridge
                    |   · audio · stats    |   + adaptive-quality
                    |   · link)            |   + dead-session cleanup
                    +----------+-----------+
                       HTTP/WS  |  127.0.0.1
              +-----------------v------------------+
              |   noVNC <-- WebSocket --> x11vnc    |  VNC server
              |                    (localhost:5900) |  on display :99
              +-------------------+-----------------+
                                  |
                         +--------v--------+
                         |  Xvfb    :99    |  headless virtual display
                         |   +-- Chrome    |  persistent profile (~/.chrome)
                         |   +-- PulseAudio|  virtual sound (null sink)
                         +-----------------+
```

### Request flow for a visitor

1. The browser hits `http://<server>:8087/<secret-path>/` and the gateway asks
   for the password.
2. A correct password issues an `HttpOnly` session cookie (`ndauth`) valid for
   30 days.
3. The gateway serves the noVNC viewer UI and the noVNC static assets.
4. The viewer opens a **WebSocket** to `/<secret-path>/vnc`; the gateway
   authenticates the cookie, then **bridges** the socket to the local VNC port
   on `127.0.0.1:5900`.
5. On connect the gateway resets the virtual keyboard to a clean state (Caps
   off, no stuck modifiers).
6. Keyboard and pointer events and framebuffer updates stream over that bridge in
   real time; audio streams over a second path from the PulseAudio sink.

The VNC server and PulseAudio daemon only ever listen on **localhost** — they are
never exposed directly to the network. The gateway is the single authenticated
entry point, and it can serve **HTTP and HTTPS together** (a generated
self-signed certificate for the TLS listener).

---

## Technology stack

| Layer | Technology |
| --- | --- |
| Gateway | Node.js + Express, `ws` for the WebSocket-to-VNC bridge |
| Virtual display | Xvfb (headless X server, display `:99`) |
| VNC server | x11vnc (bound to localhost only) |
| Browser engine | Google Chrome with a persistent profile |
| Virtual sound | PulseAudio private daemon with a null sink |
| Remote-viewer client | noVNC (WebSocket VNC client in the browser) |
| Orchestration | systemd units; interactive admin menu (`nexdesk`) |
| Installer | single POSIX `bash` script with environment overrides |

---

## Installation

### Requirements

- Debian or Ubuntu server with **systemd**, run as `root` or via `sudo`.
- About **2 GB RAM or more** recommended (Chrome runs several processes).
- A public IP, and/or open or mapped ports — **8087** for HTTP and **8443** for
  HTTPS by default.

### Quick start — one command, from anywhere

You do not need to download the repository or have it on the machine. On any
Debian/Ubuntu server with `curl` (and `sudo` for the privileged steps), run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/master/install.sh)
```

That single command fetches the installer, downloads the NexDesk source, asks a
couple of simple questions (which HTTP port to use, whether to also enable
HTTPS, whether to add swap) and installs the whole stack. At the end it prints
your **personal links** (HTTP and, by default, an HTTPS one over a generated
self-signed certificate) and the **password** — keep them secret.

> **HTTPS by default.** The installer generates a self-signed certificate
> (valid roughly two years) and serves HTTP **and** HTTPS together, so you get
> both `http://<server>:8087/...` and `https://<server>:8443/...`. Because the
> certificate is self-signed, your browser asks you to accept it once — that is
> normal and safe. Disable it with `--no-https` (or `NX_HTTPS=off`).

> The command pulls the installer from this repository's `master` branch, so the
> repository must be **publicly readable** for installs on other servers to work.

> Non-interactive runs (for example `curl -fsSL <url> | sudo bash`) skip the
> questions and use the safe defaults (HTTP port `8087`, HTTPS enabled on
> `8443`, swap offered only if missing). Every run writes a full transcript to
> `<install-dir>/logs/`.

### Update NexDesk

Updates keep your link, password and browser profile intact:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/master/install.sh) update
```

### Remove NexDesk completely

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/master/install.sh) uninstall
```

### Custom install from a checkout

If you already have the repository on the server:

```bash
sudo ./install.sh                       # defaults: /opt/nexdesk, ports 8087 + 8443
sudo ./install.sh --port 8443 --dir /opt/nexdesk
sudo ./install.sh --https-port 9443     # HTTPS on a different port
sudo ./install.sh --no-https            # HTTP only
```

> During install, if the server has no active swap the installer lets you choose
> how much to create (1/2/3/4G, or a custom size such as `512M`/`2G`), or to
> skip. NexDesk runs several Chrome processes and swap prevents out-of-memory
> kills — pick a size that fits your free disk space. To never touch swap, run
> with `NX_SWAP=off`.

Flags and their equivalent environment overrides:

| Flag | Env | Default | Meaning |
| --- | --- | --- | --- |
| `--port PORT` | `NX_PORT` | `8087` | Public HTTP listening port |
| `--https-port PORT` | `NX_HTTPS_PORT` | `8443` | Public HTTPS listening port |
| `--no-https` | `NX_HTTPS=off` | on | Also serve HTTPS (self-signed) |
| `--dir DIR` | `NX_DIR` | `/opt/nexdesk` | Install directory |
| `--user USER` | `NX_USER` | `nexdesk` | Isolated service account |
| — | `NX_SWAP` | `auto` | `off` to never touch swap |
| — | `NX_SWAPFILE` | `/swapfile` | Custom swap file path |
| — | `NX_SRC_URL` | (GitHub) | Custom source archive URL |

### What the installer does

The installer pre-flights the system (free ports, disk space, a live dpkg lock),
then:

- detects the OS and installs the engine (Chromium/Chrome, Xvfb, x11vnc, noVNC,
  PulseAudio);
- installs Node.js automatically if it is missing (NodeSource, with the distro
  package as an offline fallback), retrying `apt` if a background update holds
  the lock;
- installs the gateway dependencies and makes them readable by the service user;
- creates an **isolated service user**;
- generates the secret path, password and HMAC signing secret;
- generates the **self-signed TLS certificate** (when HTTPS is enabled);
- wires up the five `systemd` units and starts the stack;
- prints a short **health report** for every service and port;
- shows your personal HTTP **and** HTTPS links.

> The personal links already contain the secret path, and the gateway only
> responds under it — sharing a full link together with the password is what
> grants access. A full transcript of every run is saved under
> `<install-dir>/logs/installer-<timestamp>.log`. If the public IP cannot be
> reached, the final report falls back to a local IP.

---

## Uninstall

Remove NexDesk from any server without a local copy:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/NexDesk/master/install.sh) uninstall
```

From a checkout, the same thing — stops the services and removes the units, the
install directory with all data, and the service account:

```bash
sudo ./uninstall.sh               # stop services, remove units + directory + service user
sudo ./uninstall.sh --keep-user   # keep the 'nexdesk' account
```

---

## First connection

1. Open the personal link the installer printed — something like
   `http://<server>:8087/<secret-path>/`. Everything else on the server returns
   `404`.
2. Enter the password shown by the installer. A signed session cookie keeps you
   signed in for 30 days.
3. A full-screen remote Chrome appears. Use it as if it were a browser on your
   own machine — tabs, downloads and logins persist on the server between
   visits.
4. On a phone, the on-screen keyboard (English and Persian) appears for typing;
   the top bar auto-hides and returns on tap.
5. Need precise control, hover, or want to highlight text? Tap the floating
   **Mouse** pill to switch to trackpad mode — see
   [Mobile input modes](#mobile-input-modes).

To see your link, password and service status again from the server at any time,
run the admin menu (installed as `nexdesk`):

```bash
sudo nexdesk info      # print the link and password
sudo nexdesk status    # show the state of the services
sudo nexdesk           # open the full interactive menu
```

---

## Mobile input modes

On a phone or tablet the screen can be driven two ways, switched with the
floating **Mouse** pill that appears on touch devices. Both modes overlay the
viewer only — what you type never leaks onto the remote desktop's own UI.

### Touch mode (default)

The screen behaves like a touch surface:

- **Tap** — left-click at that point and open the keyboard when a text field is
  focused.
- **Drag** — pan around a zoomed (1:1) view.
- **Double-tap or floating zoom pill** — toggle between fit-to-width and 1:1,
  then drag to pan.
- **On-screen keyboard** — English and Persian layouts (symbols layer,
  ZWNJ / half-space, Tab / Esc, hold-to-repeat Backspace) appear over the
  viewer for typing and are sent as real key presses to the virtual Chrome.

### Mouse / trackpad mode

Turned on with the floating **Mouse** pill, this turns the whole screen into a
precise trackpad that drives a visible pointer — ideal for hover menus,
drag-and-drop, small targets and selecting text on a phone.

| Gesture | Result |
| --- | --- |
| Single-finger drag | Move the pointer (no click, trackpad style) |
| Tap | Left-click at the pointer |
| Press & hold (still), then drag | **Select / highlight text** — the left button stays held while you drag |
| Long hold, released without a drag | Right-click (context menu) |
| Two-finger tap | Right-click |
| Two-finger drag (up / down) | **Natural scroll** — drag up scrolls down, drag down scrolls up |

Notes:

- The pointer tracks your finger the way a laptop trackpad maps to the cursor —
  you steer it to where you want to act, then click.
- Inside Mouse mode the two-finger gestures own the screen, so use the top-bar
  zoom control (not pinch) to change the view zoom.
- Only the mobile browser's own touch handling is redirected; remote clicks,
  text selection and scrolling are ordinary VNC events, so the virtual Chrome
  sees a real mouse.
- On a device with a fine pointer (mouse / trackpad), Mouse mode is never
  offered and the classic desktop experience is unchanged.

---

## Project layout

```
NexDesk/
├── install.sh                 # one-command installer (also update / uninstall)
├── uninstall.sh               # clean teardown
├── nexdesk-admin.sh           # interactive admin menu (linked as 'nexdesk')
├── bin/
│   ├── nexdesk-browser.sh     # Chrome launcher (language, profile, window sizing)
│   └── nexdesk-audio.sh       # private PulseAudio daemon (null sink + routing)
├── src/core/gateway/
│   ├── server.js              # gateway: auth, viewer, noVNC, WS<->VNC, clipboard,
│   │                          #          audio, adaptive quality, stats
│   ├── viewer.html            # full-screen noVNC UI (top bar, keyboard, meters)
│   └── package.json           # express + ws
├── systemd/
│   ├── nexdesk-display.service
│   ├── nexdesk-vnc.service
│   ├── nexdesk-browser.service
│   ├── nexdesk-audio.service
│   └── nexdesk-gateway.service
└── assets/
    └── nexdesk-logo.png
```

Runtime secrets and data are generated under the install directory and are
**never tracked by git** (see [Security model](#security-model)):

```
/opt/nexdesk/
├── config/
│   ├── pass.txt            # login password
│   ├── webpath.txt         # secret URL path
│   └── tls/                # self-signed key + certificate
├── .secret                 # HMAC signing secret
├── .chrome/                # live Chrome profile (sessions, logins, downloads)
└── logs/                   # installer + service logs
```

---

## Configuration

### Gateway (`server.js`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8087` | HTTP listening port |
| `HTTPS_PORT` | `0` | When set to a port (and TLS files exist), also serve HTTPS |
| `TLS_KEY` | `.../tls/key.pem` | Path to the TLS private key |
| `TLS_CERT` | `.../tls/cert.pem` | Path to the TLS certificate |
| `VNC_HOST` | `127.0.0.1` | VNC host the gateway bridges to |
| `VNC_PORT` | `5900` | VNC port |
| `NOVNC_DIR` | `/usr/share/novnc` | noVNC static files |
| `PASS_FILE` | `.../config/pass.txt` | Password file |
| `WEBPATH_FILE` | `.../config/webpath.txt` | Secret path file |
| `SECRET_FILE` | `.../.secret` | Signing secret file |
| `VIEWER_FILE` | `.../viewer.html` | Viewer HTML |
| `NEXDESK_DISPLAY` | `:99` | Virtual display for clipboard/keyboard |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

### Browser (`bin/nexdesk-browser.sh`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXDESK_DISPLAY` | `:99` | Display Chrome opens on |
| `NEXDESK_CHROME` | `/usr/bin/google-chrome` | Chrome binary |
| `NEXDESK_PROFILE` | `.../.chrome` | Persistent profile |
| `NEXDESK_RES_X` | `1440` | Virtual resolution width |
| `NEXDESK_RES_Y` | `900` | Virtual resolution height |
| `NEXDESK_START_URL` | `about:blank` | Page Chrome opens with |

---

## HTTP API

All routes live under the secret path. Everything else — including the bare
root — returns `404 Not found`.

| Route | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/login` | GET | no | Show the login form |
| `/login` | POST | no | Verify password, set `ndauth` cookie |
| `/` | GET | cookie | Serve the full-screen viewer |
| `/logout` | GET | — | Clear the cookie, back to login |
| `/vnc` | WS | cookie | WebSocket to the VNC bridge |
| `/novnc/*` | GET | cookie | noVNC static assets |
| `/clipboard` | POST | cookie | Write text into the remote clipboard |
| `/api/stats` | GET | cookie | Host and per-process CPU/RAM (top-bar meter) |
| `/api/link` | GET | cookie | Live delivered throughput (kbps) and round-trip (ms) that drive Auto quality |

---

## Network tuning

NexDesk adapts to slow networks so the virtual desktop stays usable without
burning bandwidth.

- **Quality selector (top bar):** `Auto`, `High`, `Balanced` or `Low`. This
  controls the noVNC JPEG quality and compression level, which x11vnc applies
  **live** — the change takes effect in the current session with no reconnect.
- **Auto mode:** every two seconds the gateway reports the data actually
  delivered to your browser (`/api/link`) together with the round-trip time. The
  viewer smooths those values and, when the link struggles, drops quality
  immediately to keep motion fluid and data low; when the link has headroom it
  restores crispness. A small live read-out (for example `Q6 · 800 kbps · 60 ms`)
  shows the current quality, throughput and latency.
- **Auto-reconnect:** if the connection drops while the tab is open, the viewer
  reconnects on its own (a 1.5s to 8s back-off, up to five tries), including when
  you return to a tab that was in the background during the drop. Only after the
  automatic attempts are exhausted do you see a manual `Retry`.
- **Dead-session cleanup:** the gateway pings each client and drops any that stop
  responding, and tears the session down cleanly on every error and close path —
  so a visitor who vanishes never leaves a half-open connection that could block
  the next viewer.

### Memory Saver on the virtual Chrome

Chrome's *Memory Saver* (which discards background tabs to free RAM) is enabled
by default on the persistent virtual browser. It is applied as a **recommended**
policy so an operator can still toggle it inside the virtual Chrome at
`chrome://settings/performance`:

```json
# /etc/opt/chrome/policies/managed/nexdesk-performance.json
[ { "HighEfficiencyModeEnabled": { "Value": true, "level": "recommended" } } ]
```

On an already-installed server, create that file and run
`sudo systemctl restart nexdesk-browser`. It is safe on a memory-constrained host
and has no effect while you are using the active tab.

---

## Security model

- **Secret-by-obscurity, done properly** — the real app lives at an unguessable
  random path; every other request (including root) returns a generic `404`, and
  no login page is exposed at `/`.
- **Password hashing** — salted **HMAC-SHA256** keyed by a server-side secret; the
  password is never compared in plaintext, and checks are **constant-time**.
- **Signed cookie** — the `ndauth` value is an HMAC of the password under the same
  secret, marked `HttpOnly` and scoped to its path, with a 30-day expiry.
- **Local-only VNC and audio** — x11vnc and PulseAudio bind to `127.0.0.1`, never
  to a public interface; there is no second port to attack.
- **Real Chrome sandbox** is left enabled (no `--no-sandbox`).
- **Single low-privilege user** runs the services; secrets and the live profile
  are owned by it.
- **git hygiene** — `.secret`, `config/pass.txt`, `config/webpath.txt`, the
  `.chrome/` profile, logs, and lock / `node_modules` files are all gitignored so
  secrets can never be pushed.

---

## Managing the service

```bash
# Status of the whole stack
systemctl status 'nexdesk-*'

# Restart one piece (for example the gateway after a config change)
sudo systemctl restart nexdesk-gateway

# Follow the gateway logs
journalctl -u nexdesk-gateway -f

# Admin menu: connection info, status and day-to-day actions
sudo nexdesk
```

---

## Roadmap

- [ ] Optional multi-user accounts with per-user profiles
- [ ] Download forwarding from the remote to the visitor's machine
- [ ] Automatic HTTPS (Caddy / Traefik) documentation
- [ ] Docker Compose packaging for ephemeral setups

---

## License

NexDesk is released under the **NexDesk Non-Commercial License v1.0** — see
the full terms in [LICENSE](LICENSE).

In short, you may freely **use, modify, study and share** NexDesk for
**personal, educational, research and non-profit** purposes. **Attribution is
mandatory**: you must keep this license and clearly credit NexDesk and its
original author in every copy and every derived work you distribute — this
credit cannot be removed or hidden. Any **Commercial Use** — selling,
reselling, licensing, hosting or otherwise exploiting NexDesk or a modified
version of it for commercial gain — is **not permitted** without the author's
prior written consent.

Because it restricts commercial use, NexDesk is **source-available**, not
"open source" in the OSI sense of permissive licenses such as MIT or Apache-2.0
(which would allow commercial use). If you need a commercial license, contact
the maintainer.

NexDesk is an independent project and is not affiliated with, endorsed by, or
trademarked by Google, the Chromium project, or the noVNC project.
