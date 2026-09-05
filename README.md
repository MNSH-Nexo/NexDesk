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
- **English-locale Chrome** — the profile is forced to `en-US` so pages do not flip to the
  server region's language.
- **Real Chrome sandbox** — deliberately *not* launched with `--no-sandbox`.
- **Swap safety net** — during install, if the server has no active swap the installer
  asks before creating and enabling a swap file (default 4G).
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
                    |   · /api/stats)      |
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

> During install, if the server has no active swap the installer asks (y/N) whether to create a
> 4G swap file. This is recommended — NexDesk runs several Chrome processes and swap prevents
> out-of-memory kills. Decline with `n`, or skip entirely with `NX_SWAP=off`.

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

Everything **outside** the secret path — including the bare root — returns `404 Not found`.

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
- [ ] Bandwidth / adaptive quality presets in the viewer
- [ ] Download forwarding from the remote to the visitor's machine
- [ ] Automatic HTTPS (Caddy / Traefik) documentation
- [ ] Docker Compose packaging for ephemeral setups
