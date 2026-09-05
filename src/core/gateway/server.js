'use strict';
// NexDesk Gateway
// Serves everything under a secret path prefix (BASE): a login page, then a
// full-screen NexDesk viewer that embeds noVNC, plus a WebSocket->VNC bridge.
// Root and any unknown path return a plain 404 so the service stays hidden.
const express = require('express');
const http = require('http');
const https = require('https');
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { WebSocketServer, WebSocket } = require('ws');
const { spawn } = require('child_process');

const PORT = process.env.PORT || 8087;
const VNC_HOST = process.env.VNC_HOST || '127.0.0.1';
const VNC_PORT = parseInt(process.env.VNC_PORT || '5900', 10);
const NOVNC_DIR = process.env.NOVNC_DIR || '/usr/share/novnc';
const PASS_FILE = process.env.PASS_FILE || '/opt/nexdesk/config/pass.txt';
const WEBPATH_FILE = process.env.WEBPATH_FILE || '/opt/nexdesk/config/webpath.txt';
const SECRET_FILE = process.env.SECRET_FILE || '/opt/nexdesk/.secret';
const VIEWER_FILE = process.env.VIEWER_FILE || '/opt/nexdesk/src/core/gateway/viewer.html';

// Optional self-signed HTTPS listener (HTTP and HTTPS are served together).
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || '0', 10);
const TLS_KEY   = process.env.TLS_KEY   || '/opt/nexdesk/config/tls/key.pem';
const TLS_CERT  = process.env.TLS_CERT  || '/opt/nexdesk/config/tls/cert.pem';
const TLS_ENABLED = HTTPS_PORT > 0 && fs.existsSync(TLS_KEY) && fs.existsSync(TLS_CERT);
if (HTTPS_PORT > 0 && !TLS_ENABLED) {
  console.warn('[NexDesk] HTTPS requested but TLS key/cert missing (' + TLS_KEY + ') — serving HTTP only.');
}

function readFirstLine(p) { try { return fs.readFileSync(p, 'utf8').split('\n')[0].trim(); } catch (e) { return ''; } }
const SECRET = readFirstLine(SECRET_FILE) || crypto.randomBytes(16).toString('hex');
const AUTH_PASS = readFirstLine(PASS_FILE);
const WEBPATH = readFirstLine(WEBPATH_FILE) || crypto.randomBytes(12).toString('hex');

if (!AUTH_PASS) { console.error('NexDesk password file missing: ' + PASS_FILE); process.exit(1); }
if (!WEBPATH) { console.error('NexDesk webpath file missing: ' + WEBPATH_FILE); process.exit(1); }

// ---------------- lightweight structured logger ----------------
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();
const LEVELS = { debug:0, info:1, warn:2, error:3 };
const _lev = LEVELS[LOG_LEVEL] !== undefined ? LEVELS[LOG_LEVEL] : LEVELS.info;
function _ts(){ return new Date().toISOString(); }
function log(level, ...args){
  if (LEVELS[level] === undefined) level = 'info';
  if (LEVELS[level] < _lev) return;
  const out = (level==='error'||level==='warn') ? console.error : console.log;
  out(`[${_ts()}] [${level.toUpperCase().padEnd(5)}]`, ...args);
}
const L = {
  debug:  (...a)=>log('debug', ...a),
  info:   (...a)=>log('info',  ...a),
  warn:   (...a)=>log('warn',  ...a),
  error:  (...a)=>log('error', ...a),
};
const BASE = '/' + WEBPATH;              // secret path prefix

const app = express();
const server = http.createServer(app);

// Duration + status helper for request logging (debug level).
app.use((req, res, next) => {
  const t0 = Date.now();
  res.on('finish', () => {
    L.debug('http', req.method, req.originalUrl, '->', res.statusCode, (Date.now()-t0) + 'ms');
  });
  next();
});


function hash(pw, salt, secret) { return crypto.createHmac('sha256', secret).update(salt + pw).digest('hex'); }
function authed(req) {
  const m = /(?:^|;\s*)ndauth=([^;]+)/.exec(req.headers.cookie || '');
  if (!m) return false;
  const expected = crypto.createHmac('sha256', SECRET).update(AUTH_PASS).digest('base64url');
  const a = Buffer.from(m[1]); const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

app.use(express.urlencoded({ extended: true }));
app.use(express.json({ limit: '2mb' }));
const router = express.Router();

// ---- Login (under BASE) ----
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
  const ip = req.socket.remoteAddress || '?';
  if (!ok) { L.warn('login FAILED', ip); return res.redirect(BASE + '/login?err=1'); }
  L.info('login OK', ip);
  const token = crypto.createHmac('sha256', SECRET).update(AUTH_PASS).digest('base64url');
  res.setHeader('Set-Cookie', 'ndauth=' + token + '; HttpOnly; Path=/; Max-Age=2592000; SameSite=Lax');
  res.redirect(BASE + '/');
});

// ---- Home (under BASE): the NexDesk full-screen viewer ----
router.get('/', (req, res) => {
  if (!authed(req)) return res.redirect(BASE + '/login');
  fs.stat(VIEWER_FILE, (e, st) => {
    if (e || !st.isFile()){ L.error('viewer file missing', VIEWER_FILE); return res.status(500).send('Viewer not installed.'); }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    L.debug('serving viewer to', req.socket.remoteAddress);
    fs.createReadStream(VIEWER_FILE).pipe(res);
  });
});

router.get('/logout', (req, res) => { res.setHeader('Set-Cookie', 'ndauth=; HttpOnly; Path=/; Max-Age=0'); res.redirect(BASE + '/login'); });

// ---- Clipboard (under BASE): write text into the virtual desktop's X
// CLIPBOARD selection so the remote Chrome can paste it with Ctrl+V. ----
const XVFB_DISPLAY = process.env.NEXDESK_DISPLAY || ':99';

function clearRemoteKeyboard(){
  // Return the virtual desktop's keyboard to a clean state so it matches the
  // visitor's real machine: Caps Lock off, no stuck Shift/Ctrl/Alt/Meta.
  const script = 'export DISPLAY=' + JSON.stringify(XVFB_DISPLAY).replace(/"/g, '') +
    '; if xset q 2>/dev/null | grep -Eq "Caps Lock: *on"; then xdotool key Caps_Lock; fi' +
    '; xdotool keyup Shift_L Shift_R Control_L Control_R Alt_L Alt_R Meta_L Meta_R 2>/dev/null || true';
  try { const c = spawn('bash', ['-c', script]); c.on('error', () => {}); } catch (e) {}
}

function setXClipboard(text, cb){
  // Drop any previous clipboard owner so the newest copy wins (ignore no-match).
  try { const pk = spawn('pkill', ['-9', '-f', 'xclip -selection clipboard']); pk.on('error', () => {}); } catch (e) {}
  const child = spawn('xclip', ['-selection', 'clipboard', '-i'], {
    env: Object.assign({}, process.env, { DISPLAY: XVFB_DISPLAY }),
    stdio: ['pipe', 'ignore', 'ignore']
  });
  let failed = false;
  child.on('error', (e) => { failed = true; cb(e); });
  child.stdin.on('error', () => {});
  try { child.stdin.write(text); } catch (e) { failed = true; return cb(e); }
  child.stdin.end();
  // The xclip process stays alive owning the selection; answer once bytes are handed off.
  setTimeout(() => { if (!failed) cb(null); }, 150);
}
router.post('/clipboard', (req, res) => {
  if (!authed(req)) return res.status(401).end();
  const text = (req.body && typeof req.body.text === 'string') ? req.body.text : '';
  if (!text) return res.status(400).json({ ok: false, error: 'empty' });
  L.info('clipboard set bytes=' + Buffer.byteLength(text, 'utf8') + ' from ' + req.socket.remoteAddress);
  setXClipboard(text, (err) => {
    if (err) { L.warn('clipboard set error', err.message); return res.status(500).json({ ok:false, error: err.message }); }
    res.json({ ok: true });
  });
});


// ---- Resource stats (RAM/CPU) for the NexDesk top bar ----
const STAT_WINDOW_MS = 450;
function cpuSample(){
  try{
    const s = fs.readFileSync('/proc/stat', 'utf8');
    const parts = s.split('\n')[0].trim().split(/\s+/);
    let idle = (+parts[4] || 0) + (+parts[5] || 0);
    let total = 0;
    for(let i=1;i<parts.length;i++) total += (+parts[i] || 0);
    return { idle, total };
  }catch(e){ return null; }
}
function memInfoKB(){
  const m = { total:0, avail:0, swTotal:0, swFree:0 };
  try{
    const s = fs.readFileSync('/proc/meminfo', 'utf8');
    const g = (k) => { const mm = s.match(new RegExp('^' + k + ':\\s+(\\d+)\\s+kB', 'm')); return mm ? +mm[1] : 0; };
    m.total = g('MemTotal'); m.avail = g('MemAvailable');
    m.swTotal = g('SwapTotal'); m.swFree = g('SwapFree');
  }catch(e){}
  return m;
}
function procSnapshot(){
  // Aggregate CPU ticks + RSS (KiB) for NexDesk's own processes, grouped by name.
  const acc = {};
  try{
    const pids = fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d));
    for(const pid of pids){
      let comm = '';
      try{ comm = fs.readFileSync('/proc/' + pid + '/comm', 'utf8').trim(); }catch(e){ continue; }
      let group = null;
      if(comm === 'chrome') group = 'chrome';
      else if(comm === 'Xvfb') group = 'xvfb';
      else if(comm === 'x11vnc') group = 'vnc';
      if(!group) continue;
      try{
        const stat = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
        const c = stat.lastIndexOf(')');
        const rest = stat.slice(c + 2).trim().split(' ');
        // fields are 1-based after comm: rest[0] is state (field3).
        // utime=field14 -> rest[11]; stime=field15 -> rest[12]; rss=field24 -> rest[21]
        const utime = +rest[11] || 0, stime = +rest[12] || 0, rss = +rest[21] || 0;
        const a = acc[group] = acc[group] || { ticks:0, rssKB:0 };
        a.ticks += utime + stime;
        a.rssKB += rss * 4; // pages (4 KiB) -> KiB
      }catch(e){ continue; }
    }
  }catch(e){}
  return acc;
}
router.get('/api/stats', (req, res) => {
  if(!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  const mem = memInfoKB();
  const s1 = cpuSample();
  const p1 = procSnapshot();
  setTimeout(() => {
    const s2 = cpuSample();
    const p2 = procSnapshot();
    // Overall host CPU% across the measurement window.
    let cpu = 0;
    if(s1 && s2){
      const dTotal = s2.total - s1.total;
      const dIdle = s2.idle - s1.idle;
      if(dTotal > 0) cpu = Math.max(0, Math.min(100, 100 * (dTotal - dIdle) / dTotal));
    }
    // Per-group CPU% across the same window.
    const procs = [];
    const dCpuTotal = (s1 && s2) ? (s2.total - s1.total) : 0;
    for(const name in p2){
      const prev = p1[name]; const cur = p2[name];
      let pcpu = 0;
      if(prev && dCpuTotal > 0) pcpu = Math.max(0, Math.min(100, 100 * (cur.ticks - prev.ticks) / dCpuTotal));
      procs.push({ name, cpu: Math.round(pcpu * 10) / 10, memKB: cur.rssKB });
    }
    res.json({
      ok: true,
      cpu: Math.round(cpu * 10) / 10,
      memMB: {
        total: Math.round(mem.total / 1024),
        used: Math.round((mem.total - mem.avail) / 1024),
        swap: Math.round((mem.swTotal - mem.swFree) / 1024)
      },
      procs
    });
  }, STAT_WINDOW_MS);
});

// ---- Live link metrics for the viewer's auto-quality engine ----
// The gateway measures how many bytes are actually flowing to the active
// viewer each second plus the round-trip latency (ws ping/pong), so the page
// can adapt image quality to the real connection without reconnecting.
let linkState = { txRateKbps: 0, rttMs: 0 };
router.get('/api/link', (req, res) => {
  if(!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  res.json({ ok:true, txRateKbps: Math.round(linkState.txRateKbps), rttMs: Math.round(linkState.rttMs) });
});

// ---- noVNC static assets (under BASE) ----
router.use('/novnc', (req, res, next) => {
  if (!authed(req)) return res.redirect(BASE + '/login');
  const rel = req.path === '/' ? 'vnc.html' : req.path;
  const file = path.normalize(path.join(NOVNC_DIR, rel));
  if (!file.startsWith(NOVNC_DIR)) return res.status(403).end();
  fs.stat(file, (e, st) => {
    if (e || st.isDirectory()){ L.debug('novnc 404', rel, '->', file); return res.status(404).end(); }
    res.sendFile(file);
  });
});

app.use(BASE, router);

// Any path outside BASE (including root) -> 404, hiding the service.
app.use((req, res) => res.status(404).type('text/plain').send('Not found.'));

// ---- WebSocket <-> VNC bridge (only under BASE/vnc) ----
const wss = new WebSocketServer({ noServer: true });

// Shared by both the HTTP and (optional) HTTPS listeners, so a viewer over
// either scheme can reach the same VNC bridge.
function handleUpgrade(req, socket, head) {
  const u = req.url || '';
  const ip = req.socket.remoteAddress || '?';
  const q = u.split('?')[0];
  if (q !== BASE + '/vnc') return socket.destroy();
  const ok = authed(req);
  if (!ok) { L.warn('ws upgrade REJECTED (auth)', ip, q); return socket.destroy(); }
  L.info('ws upgrade accepted', ip, q);
  wss.handleUpgrade(req, socket, head, (ws) => {
    L.debug('ws client open', ip);
    const tcp = net.connect(VNC_PORT, VNC_HOST, () => {});
    let tcpReady = false;
    let rxBytes = 0, txBytes = 0;   // client->server (rx) and server->client (tx) over the TCP/VNC side
    const RATE_SEC = 5;
    const rateTimer = setInterval(() => {
      if (rxBytes + txBytes > 0) L.debug('ws traffic', ip, 'tx=' + txBytes + 'B rx=' + rxBytes + 'B /' + RATE_SEC + 's');
      rxBytes = 0; txBytes = 0;
    }, RATE_SEC * 1000).unref();
    // Per-second delivery rate + latency, exposed to the viewer's auto-quality.
    let lastPingAt = 0, noPong = 0;
    ws.on('pong', () => { if (lastPingAt) { linkState.rttMs = Date.now() - lastPingAt; noPong = 0; } });
    const wsTx = { bytes: 0 };
    const metricTimer = setInterval(() => {
      linkState.txRateKbps = (wsTx.bytes * 8) / 1000;   // bytes in 1s -> kilobits/s
      wsTx.bytes = 0;
      lastPingAt = Date.now();
      try { ws.ping(); noPong++; } catch (e) { lastPingAt = 0; }
      // ~4s without a pong means the client's network died silently; drop the
      // session so the VNC socket is freed and a fresh reconnect can succeed.
      if (noPong >= 4) teardown('noPong');
    }, 1000).unref();
    // Single, idempotent teardown wired to every exit path (ws close/error and
    // vnc end/error). This guarantees a dropped client never leaves a zombie
    // half-open connection to x11vnc that would block the next viewer.
    let ended = false;
    function teardown(why) {
      if (ended) return;
      ended = true;
      clearInterval(rateTimer);
      clearInterval(metricTimer);
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        try { ws.close(1000, 'bridge end'); } catch (_) {}
      }
      try { tcp.destroy(); } catch (_) {}
      L.info('ws session end', ip, 'reason=' + why);
    }
    ws.on('message', (data) => { if (tcpReady) tcp.write(data); rxBytes += data.length; });
    ws.on('close', (code) => { teardown('clientClose code=' + code); });
    ws.on('error', (e) => { L.warn('ws client error', ip, e.message); teardown('clientError'); });
    tcp.on('connect', () => { tcpReady = true; L.debug('vnc tcp connected', ip, VNC_HOST + ':' + VNC_PORT); clearRemoteKeyboard(); });
    tcp.on('data', (d) => { txBytes += d.length; wsTx.bytes += d.length; if (ws.readyState === WebSocket.OPEN) ws.send(d); });
    tcp.on('end', () => { L.warn('vnc tcp closed by server', ip); teardown('vncEnd'); });
    tcp.on('error', (e) => { L.error('vnc tcp error', ip, e.message); teardown('vncError'); });
  });
}
server.on('upgrade', handleUpgrade);

server.listen(PORT, '0.0.0.0', () => L.info('NexDesk gateway listening on port ' + PORT + ' (log=' + LOG_LEVEL + ')'));

// Optional self-signed HTTPS listener, sharing the same app, auth and bridge.
if (TLS_ENABLED) {
  const httpsServer = https.createServer({
    key: fs.readFileSync(TLS_KEY),
    cert: fs.readFileSync(TLS_CERT),
  }, app);
  httpsServer.on('upgrade', handleUpgrade);
  httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => L.info('NexDesk TLS gateway listening on port ' + HTTPS_PORT + ' (log=' + LOG_LEVEL + ')'));
}
