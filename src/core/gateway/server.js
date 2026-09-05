'use strict';
// NexDesk Gateway - secret-path login + noVNC client + WebSocket->VNC bridge.
const express = require('express');
const http = require('http');
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { WebSocketServer, WebSocket } = require('ws');

const PORT = process.env.PORT || 8087;
const VNC_HOST = process.env.VNC_HOST || '127.0.0.1';
const VNC_PORT = parseInt(process.env.VNC_PORT || '5900', 10);
const NOVNC_DIR = process.env.NOVNC_DIR || '/usr/share/novnc';
const PASS_FILE = process.env.PASS_FILE || '/opt/nexdesk/config/pass.txt';
const WEBPATH_FILE = process.env.WEBPATH_FILE || '/opt/nexdesk/config/webpath.txt';
const SECRET_FILE = '/opt/nexdesk/.secret';

function readFirstLine(p) { try { return fs.readFileSync(p, 'utf8').split('\n')[0].trim(); } catch (e) { return ''; } }
const SECRET = readFirstLine(SECRET_FILE) || crypto.randomBytes(16).toString('hex');
const AUTH_PASS = readFirstLine(PASS_FILE);
const WEBPATH = readFirstLine(WEBPATH_FILE) || crypto.randomBytes(12).toString('hex');

if (!AUTH_PASS) { console.error('NexDesk password file missing: ' + PASS_FILE); process.exit(1); }
if (!WEBPATH) { console.error('NexDesk webpath file missing: ' + WEBPATH_FILE); process.exit(1); }

const BASE = '/' + WEBPATH;              // secret path prefix, e.g. /7H9m9fsHNl9y7jvfJIhMVBNojJs0

const app = express();
const server = http.createServer(app);

function hash(pw, salt, secret) { return crypto.createHmac('sha256', secret).update(salt + pw).digest('hex'); }
function authed(req) {
  const m = /(?:^|;\s*)ndauth=([^;]+)/.exec(req.headers.cookie || '');
  if (!m) return false;
  const expected = crypto.createHmac('sha256', SECRET).update(AUTH_PASS).digest('base64url');
  const a = Buffer.from(m[1]); const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Everything lives under the secret BASE. The root and any other path return
// 404 (no redirect, no banner) so the service stays hidden unless you know the path.
app.use(express.urlencoded({ extended: true }));

// ---- Login (under BASE) ----
const router = express.Router();

router.get('/login', (req, res) => {
  if (authed(req)) return res.redirect(BASE + '/');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(`<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NexDesk</title>
<style>
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,sans-serif;background:radial-gradient(1200px 600px at 80% -10%,#2b1a5e 0%,#0d0b1a 55%);min-height:100vh;display:flex;align-items:center;justify-content:center;color:#fff;padding:20px}
.card{background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.12);backdrop-filter:blur(14px);border-radius:22px;padding:38px 34px;width:100%;max-width:380px;box-shadow:0 30px 80px rgba(0,0,0,.5)}
.logo{display:flex;align-items:center;gap:12px;margin-bottom:6px}.logo .dot{width:42px;height:42px;border-radius:12px;background:linear-gradient(135deg,#7c5cff,#39d0ff);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:22px}
h1{margin:0;font-size:20px} p.sub{margin:4px 0 26px;color:#b9b3dd;font-size:13px}
input{width:100%;padding:13px 14px;border-radius:12px;border:1px solid rgba(255,255,255,.18);background:rgba(255,255,255,.06);color:#fff;font-size:15px;margin-bottom:14px}
input::placeholder{color:#8b86ad}
button{width:100%;padding:13px;border:0;border-radius:12px;background:linear-gradient(135deg,#7c5cff,#39d0ff);color:#fff;font-size:15px;font-weight:700;cursor:pointer}
button:hover{filter:brightness(1.08)}
.err{background:rgba(255,80,90,.15);border:1px solid rgba(255,120,130,.4);color:#ffb3b8;padding:10px 12px;border-radius:10px;font-size:13px;margin-bottom:14px}
</style></head><body><div class="card">
<div class="logo"><div class="dot">N</div><h1>NexDesk</h1></div>
<p class="sub">مرورگر مجازی شما — برای دسترسی رمز عبور را وارد کنید.</p>
${req.query.err ? '<div class="err">رمز عبور نادرست است.</div>' : ''}
<form method="post" action="${BASE}/login">
<input type="password" name="pw" placeholder="رمز عبور" autofocus autocomplete="current-password">
<button type="submit">ورود و باز کردن NexDesk</button>
</form></div></body></html>`);
});

router.post('/login', (req, res) => {
  const salt = crypto.randomBytes(16).toString('hex');
  const ok = crypto.timingSafeEqual(Buffer.from(hash(req.body.pw || '', salt, SECRET)), Buffer.from(hash(AUTH_PASS, salt, SECRET)));
  if (!ok) return res.redirect(BASE + '/login?err=1');
  const token = crypto.createHmac('sha256', SECRET).update(AUTH_PASS).digest('base64url');
  res.setHeader('Set-Cookie', 'ndauth=' + token + '; HttpOnly; Path=/; Max-Age=2592000; SameSite=Lax');
  res.redirect(BASE + '/');
});

// ---- Home (under BASE): straight into the virtual browser ----
router.get('/', (req, res) => {
  if (!authed(req)) return res.redirect(BASE + '/login');
  const vncUrl = BASE + '/novnc/vnc.html?autoconnect=true&resize=scale&path=' + encodeURIComponent(WEBPATH + '/vnc') + '&reconnect=true&reconnect_delay=2000';
  res.redirect(vncUrl);
});

router.get('/logout', (req, res) => { res.setHeader('Set-Cookie', 'ndauth=; HttpOnly; Path=/; Max-Age=0'); res.redirect(BASE + '/login'); });

// ---- noVNC static (under BASE) ----
router.use('/novnc', (req, res, next) => {
  if (!authed(req)) return res.redirect(BASE + '/login');
  const rel = req.path === '/' ? 'vnc.html' : req.path;
  const file = path.normalize(path.join(NOVNC_DIR, rel));
  if (!file.startsWith(NOVNC_DIR)) return res.status(403).end();
  fs.stat(file, (e, st) => { if (e || st.isDirectory()) return res.status(404).end(); res.sendFile(file); });
});

app.use(BASE, router);

// Any path outside BASE (including root) -> 404, hiding the service.
app.use((req, res) => res.status(404).type('text/plain').send('Not found.'));

// ---- WebSocket <-> VNC bridge (only under BASE/vnc) ----
const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const u = req.url || '';
  if (!u.startsWith(BASE + '/vnc') && !u.startsWith(BASE + '/websockify')) return socket.destroy();
  if (!authed(req)) return socket.destroy();
  wss.handleUpgrade(req, socket, head, (ws) => {
    const tcp = net.connect(VNC_PORT, VNC_HOST, () => {});
    let tcpReady = false;
    ws.on('message', (data) => { if (tcpReady) tcp.write(data); });
    ws.on('close', () => tcp.destroy());
    tcp.on('connect', () => { tcpReady = true; });
    tcp.on('data', (d) => { if (ws.readyState === WebSocket.OPEN) ws.send(d); });
    tcp.on('error', () => ws.close());
  });
});

server.listen(PORT, '0.0.0.0', () => console.log('NexDesk gateway on port ' + PORT));
