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
const { spawn, spawnSync } = require('child_process');

const PORT = process.env.PORT || 8087;
const VNC_HOST = process.env.VNC_HOST || '127.0.0.1';
const VNC_PORT = parseInt(process.env.VNC_PORT || '5900', 10);
const NOVNC_DIR = process.env.NOVNC_DIR || '/usr/share/novnc';
// Cache-busting key for the noVNC static assets. The viewer asks for its files
// under /novnc/v<key>/... so a stale page kept in the browser cache never hits a
// URL the server cannot still answer: any /v<key>/ prefix is stripped by the
// /novnc router, so every previously-served address keeps working. The key only
// changes when the actual noVNC files on disk change.
const NOVNC_KEY = (function () {
  try {
    const names = fs.readdirSync(NOVNC_DIR).sort();
    const sig = names.map((n) => {
      try { return n + ':' + fs.statSync(path.join(NOVNC_DIR, n)).mtimeMs; } catch (e) { return n + ':?'; }
    }).join('|');
    return crypto.createHash('sha1').update(sig).digest('hex').slice(0, 10);
  } catch (e) { return '0000000000'; }
})();
const PASS_FILE = process.env.PASS_FILE || '/opt/nexdesk/config/pass.txt';
const WEBPATH_FILE = process.env.WEBPATH_FILE || '/opt/nexdesk/config/webpath.txt';
const SECRET_FILE = process.env.SECRET_FILE || '/opt/nexdesk/.secret';
const VIEWER_FILE = process.env.VIEWER_FILE || '/opt/nexdesk/src/core/gateway/viewer.html';

// ---- NexDesk "My Files" + file management (upload/download/list/delete) ----
// A clean, dedicated folder on the virtual desktop (owned by the nexdesk user)
// so files uploaded from the visitor's machine also appear inside the virtual
// browser's own file picker under /home/nexdesk/MyFiles.
const MYFILES_DIR = process.env.MYFILES_DIR || '/home/nexdesk/MyFiles';
const MYFILES_MAX_UPLOAD = parseInt(process.env.MYFILES_MAX_MB || '2048', 10) * 1024 * 1024; // default 2 GiB per file
const LOG_DIR = process.env.LOG_DIR || '/opt/nexdesk/logs';

// ---- Live audio bridge (virtual desktop sound -> visitor's browser) ----
// PulseAudio (run by nexdesk-audio.service) exposes the mixed desktop sound on
// a monitor source. The gateway spawns one `parec` capture per listening viewer
// and streams raw PCM frames over an authenticated WebSocket. Config knobs let
// an operator tune the default capture format without a redeploy.
const AUDIO_RUNTIME_DIR = process.env.AUDIO_RUNTIME_DIR || '/run/nexdesk-audio';
const AUDIO_SINK = process.env.AUDIO_SINK || 'nxsink';
const AUDIO_SOURCE = process.env.AUDIO_SOURCE || (AUDIO_SINK + '.monitor');
const AUDIO_DEFAULT_RATE = parseInt(process.env.AUDIO_RATE || '44100', 10);
const AUDIO_DEFAULT_CHANNELS = parseInt(process.env.AUDIO_CHANNELS || '1', 10);
const AUDIO_MAX_RATE = 96000;
const AUDIO_MIN_RATE = 8000;
// When no audio client is connected we do not run the capture at all, so a quiet
// idle server burns no extra CPU on its single core.
const AUDIO_IDLE_POLL_MS = 250;

// Optional self-signed HTTPS listener (HTTP and HTTPS are served together).
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || '0', 10);
const TLS_KEY   = process.env.TLS_KEY   || '/opt/nexdesk/config/tls/key.pem';
const TLS_CERT  = process.env.TLS_CERT  || '/opt/nexdesk/config/tls/cert.pem';
const TLS_ENABLED = HTTPS_PORT > 0 && fs.existsSync(TLS_KEY) && fs.existsSync(TLS_CERT);
if (HTTPS_PORT > 0 && !TLS_ENABLED) {
  console.warn('[NexDesk] HTTPS requested but TLS key/cert missing (' + TLS_KEY + ') — serving HTTP only.');
}

// Build version of the currently running code. Every deploy is commit + push +
// service restart, so the git short hash uniquely identifies a release. The
// viewer polls this and refreshes itself automatically whenever a newer build
// goes live, so visitors never need to clear their browser cache.
const APP_VERSION = (() => {
  // systemd services often run with a minimal PATH, so give the child a known
  // PATH or git itself would not be found. The service also runs as a user that
  // does not own the checkout, so add a scoped safe.directory exception (this
  // affects only this one read-only git child, never the repository or config).
  const gitEnv = Object.assign({}, process.env, {
    PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'safe.directory',
    GIT_CONFIG_VALUE_0: '*',
  });
  try {
    const repo = path.dirname(VIEWER_FILE);            // inside the git checkout
    const r = spawnSync('git', ['-C', repo, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8', timeout: 3000, env: gitEnv });
    if (r && !r.status && r.stdout && r.stdout.trim()) return r.stdout.trim();
  } catch (e) {}
  try { return String(fs.statSync(VIEWER_FILE).mtimeMs); } catch (e) {}
  return 'dev';
})();

// Cache policy: HTML documents and JSON APIs must never be cached so a visitor
// always receives the newest build. noVNC static assets are revalidated on each
// request (cheap 304 when unchanged) which is enough to keep them fresh too.
function noStore(res) { res.setHeader('Cache-Control', 'no-store'); }
function noCache(res) { res.setHeader('Cache-Control', 'no-cache, must-revalidate'); }

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

// ---- file-backed operational logs (append-only, for easier debugging) ----
try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch (e) {}
function writeLogFile(file, line){
  try { fs.appendFileSync(path.join(LOG_DIR, file), '[' + new Date().toISOString() + '] ' + line + '\n'); }
  catch (e) {}
}
const LFILE = {
  files:  (s) => writeLogFile('files.log',  s),
  upload: (s) => writeLogFile('upload.log', s),
  audio:  (s) => writeLogFile('audio.log',  s),
};

// ---- My Files path-safety + listing helpers ----
function safeFileName(name){
  if (typeof name !== 'string') return null;
  let n = name.replace(/\\/g, '/').split('/').pop() || '';
  n = n.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (!n || n === '.' || n === '..' || n === '/' || n.length > 255) return null;
  // reject absolute-ish and traversal leftovers after basename split
  if (n.includes('/') || n.includes('\0')) return null;
  return n;
}
function safeRelPath(name){
  const n = safeFileName(name);
  if (!n) return null;
  const full = path.resolve(MYFILES_DIR, n);
  if (full !== MYFILES_DIR && !full.startsWith(MYFILES_DIR + path.sep)) return null; // must stay inside
  return { rel: n, full };
}
function ensureMyFiles(){
  try { fs.mkdirSync(MYFILES_DIR, { recursive: true }); return true; }
  catch (e) { L.error('cannot create MyFiles dir', MYFILES_DIR, e.message); return false; }
}
function sweepOrphanParts(){
  // Best-effort cleanup of temp uploads (.nx-upload-*.part) left behind by
  // interrupted transfers, so a dropped connection never leaves clutter on disk.
  try {
    const now = Date.now();
    for (const f of fs.readdirSync(MYFILES_DIR)) {
      if (!/^\.nx-upload-.*\.part$/.test(f)) continue;
      try {
        const full = path.join(MYFILES_DIR, f);
        if (now - fs.statSync(full).mtimeMs > 60000) fs.unlinkSync(full);
      } catch (e) {}
    }
  } catch (e) {}
}
sweepOrphanParts();
const TYPE_BY_EXT = {
  '.png': 'image','.jpg':'image','.jpeg':'image','.gif':'image','.webp':'image','.svg':'image','.bmp':'image','.ico':'image','.avif':'image','.heic':'image',
  '.mp4':'video','.webm':'video','.mkv':'video','.mov':'video','.avi':'video','.m4v':'video','.mpg':'video','.mpeg':'video',
  '.mp3':'audio','.wav':'audio','.ogg':'audio','.flac':'audio','.m4a':'audio','.aac':'audio','.opus':'audio',
  '.pdf':'pdf','.doc':'doc','.docx':'doc','.xls':'sheet','.xlsx':'sheet','.ppt':'slides','.pptx':'slides','.odt':'doc','.ods':'sheet','.odp':'slides','.txt':'text','.md':'text','.csv':'sheet','.rtf':'text','.json':'code','.js':'code','.ts':'code','.html':'code','.css':'code','.xml':'code','.py':'code','.zip':'archive','.rar':'archive','.7z':'archive','.tar':'archive','.gz':'archive','.bz2':'archive','.xz':'archive',
};
function fileTypeIcon(name){
  const i = String(name).toLowerCase().lastIndexOf('.');
  const ext = i >= 0 ? String(name).slice(i) : '';
  return TYPE_BY_EXT[ext] || 'file';
}
function listMyFiles(){
  if (!ensureMyFiles()) return [];
  try {
    return fs.readdirSync(MYFILES_DIR).filter((f) => !f.startsWith('.')).map((f) => {
      let st = null; try { st = fs.statSync(path.join(MYFILES_DIR, f)); } catch (e) {}
      if (!st || st.isDirectory()) return null;
      return { name: f, size: st.size, mtime: st.mtimeMs, type: fileTypeIcon(f) };
    }).filter(Boolean).sort((a, b) => b.mtime - a.mtime);
  } catch (e) { L.error('listMyFiles error', e.message); return []; }
}
function humanBytes(b){
  if (!Number.isFinite(b) || b < 0) return '–';
  if (b < 1024) return b + ' B';
  const u = ['KB','MB','GB','TB']; let v = b, i = -1;
  do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
  return (v >= 100 ? Math.round(v) : Math.round(v * 10) / 10) + ' ' + u[i];
}

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

// Tag every BASE response with the running build (visible in dev tools).
router.use((req, res, next) => { res.setHeader('X-NexDesk-Version', APP_VERSION); next(); });

// ---- Login (under BASE) ----
router.get('/login', (req, res) => {
  if (authed(req)) return res.redirect(BASE + '/');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  noStore(res);
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
<div class="logo"><div class="dot" aria-hidden="true" style="background-image:url('data:image/png;base64,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');background-size:cover;background-position:center;background-color:transparent"></div><h1>NexDesk</h1></div>
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
  fs.readFile(VIEWER_FILE, 'utf8', (e, html) => {
    if (e){ L.error('viewer file missing', VIEWER_FILE); return res.status(500).send('Viewer not installed.'); }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    noStore(res);
    res.setHeader('X-NexDesk-Version', APP_VERSION);
    // Stamp the current noVNC cache-busting key into the page so its module
    // imports point at /novnc/v<key>/... (served for any key, old or new).
    res.send(html.split('__NOVNC_KEY__').join(NOVNC_KEY));
    L.debug('serving viewer to', req.socket.remoteAddress);
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
  noStore(res);
  const text = (req.body && typeof req.body.text === 'string') ? req.body.text : '';
  if (!text) return res.status(400).json({ ok: false, error: 'empty' });
  L.info('clipboard set bytes=' + Buffer.byteLength(text, 'utf8') + ' from ' + req.socket.remoteAddress);
  setXClipboard(text, (err) => {
    if (err) { L.warn('clipboard set error', err.message); return res.status(500).json({ ok:false, error: err.message }); }
    res.json({ ok: true });
  });
});


// JSON APIs are never cached, so live metrics and the version poll are always fresh.
router.use('/api', (req, res, next) => { noStore(res); next(); });

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

// ---- Running build version (drives the viewer's auto-update) ----
router.get('/api/version', (req, res) => {
  if(!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  res.json({ ok:true, version: APP_VERSION });
});

// ---- Upload-injection: "choose file" inside the virtual browser ----
// GET: does the virtual browser currently want a file? (viewer polls this)
router.get('/api/chooser', (req, res) => {
  if(!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  if (!cdp.pending) return res.json({ ok:true, pending:false, enabled: cdp.enabled });
  res.json({ ok:true, pending:true, mode: cdp.pending.mode, since: Math.round((Date.now()-cdp.pending.at)/1000) });
});

// POST: the visitor picked an uploaded file to feed to the site, or cancelled.
router.post('/api/chooser', async (req, res) => {
  if(!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  const action = req.body && req.body.action;
  if (action === 'cancel') {
    cdpCancelPending('viewerCancel');
    return res.json({ ok:true });
  }
  if (action === 'inject') {
    const name = safeFileName(req.body && req.body.file);
    if (!name) return res.status(400).json({ ok:false, error:'invalid file' });
    const full = path.resolve(MYFILES_DIR, name);
    if (!full.startsWith(MYFILES_DIR + path.sep)) return res.status(400).json({ ok:false, error:'invalid file' });
    let st = null; try { st = fs.statSync(full); } catch (e) {}
    if (!st || st.isDirectory()) return res.status(404).json({ ok:false, error:'file not found' });
    const r = await cdpInject(full);
    return res.json(r.ok ? { ok:true } : { ok:false, error:r.error });
  }
  return res.status(400).json({ ok:false, error:'bad action' });
});

// ---- My Files: list, upload (binary PUT), download, delete ----
// All under BASE and cookie-authenticated. Uploads are streamed to a temporary
// file then atomically renamed into place, so a dropped connection can never
// leave a half-written file behind.
router.get('/api/files', (req, res) => {
  if (!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  const files = listMyFiles().map((f) => ({
    name: f.name, size: f.size, sizeLabel: humanBytes(f.size), mtime: f.mtime, type: f.type,
  }));
  LFILE.files('LIST ok from ' + (req.socket.remoteAddress || '?') + ' -> ' + files.length + ' files');
  L.debug('api/files', files.length, 'files');
  res.json({ ok: true, files });
});

router.put('/api/files', (req, res) => {
  if (!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  if (!ensureMyFiles()) return res.status(500).json({ ok:false, error:'storage unavailable' });
  const ip = req.socket.remoteAddress || '?';
  const name = safeFileName(req.query.name || req.headers['x-file-name'] || '');
  if (!name) return res.status(400).json({ ok:false, error:'invalid file name' });
  const target = path.resolve(MYFILES_DIR, name);
  if (!target.startsWith(MYFILES_DIR + path.sep)) return res.status(400).json({ ok:false, error:'invalid file name' });
  const declared = parseInt(req.headers['content-length'] || '0', 10);
  if (declared > MYFILES_MAX_UPLOAD) {
    LFILE.upload('REJECT size-limit name=' + name + ' declared=' + declared + ' from ' + ip);
    return res.status(413).json({ ok:false, error:'file too large (max ' + (MYFILES_MAX_UPLOAD/1048576) + ' MiB)' });
  }
  const tmp = path.join(MYFILES_DIR, '.nx-upload-' + Date.now() + '-' + crypto.randomBytes(4).toString('hex') + '.part');
  const started = Date.now();
  let got = 0, done = false, aborted = false;
  const out = fs.createWriteStream(tmp, { flags: 'wx', mode: 0o644 });
  function fail(code, msg, extra){
    if (done) return; done = true; aborted = true;
    try { out.destroy(); } catch (e) {}
    try { req.destroy(); } catch (e) {}
    try { fs.unlinkSync(tmp); } catch (e) {}
    LFILE.upload('FAIL ' + msg + ' name=' + name + ' bytes=' + got + ' from ' + ip);
    L.warn('upload fail', name, msg, extra || '');
    if (!res.headersSent) res.status(code).json({ ok:false, error:msg });
  }
  req.on('data', (chunk) => {
    if (aborted) return;
    got += chunk.length;
    if (got > MYFILES_MAX_UPLOAD) return fail(413, 'file too large');
    if (out.writable) { try { out.write(chunk); } catch (e) {} }
  });
  req.on('error', () => fail(400, 'upload interrupted'));
  req.on('aborted', () => fail(499, 'upload aborted (client closed)'));
  out.on('error', (e) => fail(500, 'write error'));
  req.on('end', () => {
    if (aborted || done) return;
    out.end(() => {
      try { fs.renameSync(tmp, target); }
      catch (e) { fail(500, 'finalize error'); return; }
      done = true;
      const secs = ((Date.now() - started) / 1000).toFixed(2);
      LFILE.upload('OK name=' + name + ' bytes=' + got + ' secs=' + secs + ' from ' + ip);
      L.info('upload ok', name, got, 'bytes in', secs + 's');
      res.json({ ok:true, file:{ name, size: got, sizeLabel: humanBytes(got) } });
    });
  });
});

router.delete('/api/files/:name', (req, res) => {
  if (!authed(req)) return res.status(401).json({ ok:false, error:'unauthorized' });
  const rel = safeRelPath(decodeURIComponent(req.params.name || ''));
  if (!rel) return res.status(400).json({ ok:false, error:'invalid name' });
  try {
    fs.unlinkSync(rel.full);
    LFILE.files('DELETE ok name=' + rel.rel + ' from ' + (req.socket.remoteAddress || '?'));
    L.info('file deleted', rel.rel);
    return res.json({ ok:true });
  } catch (e) {
    if (e.code === 'ENOENT') return res.json({ ok:true });
    LFILE.files('DELETE FAIL name=' + rel.rel + ' ' + e.message);
    return res.status(500).json({ ok:false, error:'delete failed' });
  }
});

router.get('/api/files/:name/download', (req, res) => {
  if (!authed(req)) return res.status(401).end();
  const rel = safeRelPath(decodeURIComponent(req.params.name || ''));
  if (!rel) return res.status(400).end();
  let st = null; try { st = fs.statSync(rel.full); } catch (e) {}
  if (!st || st.isDirectory()) return res.status(404).end();
  const ascii = rel.rel.replace(/[^\x20-\x7e]/g, '_');
  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Length', st.size);
  res.setHeader('Content-Disposition', 'attachment; filename="' + ascii + '"; filename*=UTF-8\'\'' + encodeURIComponent(rel.rel));
  noStore(res);
  LFILE.files('DOWNLOAD name=' + rel.rel + ' size=' + st.size + ' from ' + (req.socket.remoteAddress || '?'));
  L.debug('file download', rel.rel);
  fs.createReadStream(rel.full).pipe(res);
});

// ---- noVNC static assets (under BASE) ----
// The viewer loads these under /novnc/v<key>/... (any key is accepted — the
// optional v-prefixed segment is only a cache-buster, so addresses served by
// earlier versions of the page keep working and can never 404). Plain
// /novnc/... URLs are served as well. Files are revalidated on each request.
router.use('/novnc', (req, res, next) => {
  if (!authed(req)) return res.redirect(BASE + '/login');
  let rel = req.path.replace(/^\/v[\w.-]+\//, '/');  // strip optional /v<key>/ cache-busting prefix
  if (rel === '/') rel = 'vnc.html';
  const file = path.normalize(path.join(NOVNC_DIR, rel));
  if (!file.startsWith(NOVNC_DIR)) return res.status(403).end();
  fs.stat(file, (e, st) => {
    if (e || st.isDirectory()){
      L.warn('novnc 404', req.originalUrl, '->', file);
      return res.status(404).end();
    }
    noCache(res);                       // revalidate each request (304 when unchanged)
    res.sendFile(file);
  });
});

app.use(BASE, router);

// Any path outside BASE (including root) -> 404, hiding the service.
app.use((req, res) => res.status(404).type('text/plain').send('Not found.'));

// ---- WebSocket <-> VNC bridge (only under BASE/vnc) ----
const wss = new WebSocketServer({ noServer: true });

// ===================== Live audio bridge =====================
// Every listening viewer opens an authenticated WebSocket under BASE/audio. The
// gateway spawns one `parec` capture (from the PulseAudio monitor of the virtual
// desktop's sink) and forwards raw PCM int16 frames to that viewer. To save
// bandwidth/CPU on a quiet desktop we drop near-digital-silence buffers — the
// browser fills the gaps with silence locally, so you hear audio exactly when
// there is audio and idle traffic stays ~zero.
const AUDIO_SILENCE_THRESHOLD = parseInt(process.env.AUDIO_SILENCE || '12', 10); // int16 amplitude
const audioRuntime = (function () {
  try { fs.mkdirSync(AUDIO_RUNTIME_DIR, { recursive: true }); } catch (e) {}
  return AUDIO_RUNTIME_DIR;
})();
function audioEnv(){
  return Object.assign({}, process.env, {
    PULSE_SERVER: 'unix:' + audioRuntime + '/pulse/native',
    PULSE_RUNTIME_PATH: audioRuntime + '/pulse',
    XDG_RUNTIME_DIR: audioRuntime,
    HOME: process.env.HOME || '/home/nexdesk',
  });
}
function clampInt(v, min, max, dflt){
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.max(min, Math.min(max, n));
}
function samplePeak(buf){
  // int16 little-endian PCM -> max absolute sample amplitude
  if (!buf || buf.length < 2) return 0;
  let peak = 0;
  const n = buf.length - (buf.length % 2);
  for (let i = 0; i < n; i += 2){
    const s = buf.readInt16LE(i);
    const a = s < 0 ? -s : s;
    if (a > peak){ if (a > 30000) return a; peak = a; }
  }
  return peak;
}

function handleAudioUpgrade(req, socket, head, ip){
  let u = null; try { u = new URL(req.url, 'http://x'); } catch (e) { socket.destroy(); return; }
  const q = (u.pathname || '');
  if (q !== BASE + '/audio') return socket.destroy();
  if (!authed(req)) { LFILE.audio('REJECT auth ' + ip); socket.destroy(); return; }
  const rate = clampInt(u.searchParams.get('rate'), AUDIO_MIN_RATE, AUDIO_MAX_RATE, AUDIO_DEFAULT_RATE);
  const channels = clampInt(u.searchParams.get('channels'), 1, 2, AUDIO_DEFAULT_CHANNELS);
  const aSrv = new WebSocketServer({ noServer: true });
  aSrv.handleUpgrade(req, socket, head, (ws) => {
    const started = Date.now();
    let loudBytes = 0, silentBytes = 0, chunks = 0;
    let child = null, childExited = false, closed = false;
    const env = audioEnv();
    LFILE.audio('OPEN rate=' + rate + ' ch=' + channels + ' from ' + ip);
    L.info('audio stream open', ip, rate + 'Hz/' + channels + 'ch');
    ws.send(JSON.stringify({ type: 'config', rate, channels, format: 's16le' }), () => {});
    function stop(why){
      if (closed) return; closed = true;
      const dur = ((Date.now() - started) / 1000).toFixed(1);
      if (child) { try { child.kill('SIGTERM'); } catch (e) {} }
      const kb = (loudBytes + silentBytes) / 1024;
      LFILE.audio('CLOSE ' + why + ' dur=' + dur + 's loud=' + Math.round(loudBytes/1024) + 'KB silent=' + Math.round(silentBytes/1024) + 'KB from ' + ip);
      L.info('audio stream end', ip, 'reason=' + why, 'dur=' + dur + 's', Math.round(kb) + 'KB');
      try { aSrv.close(); } catch (e) {}
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING){
        try { ws.close(1000, why); } catch (e) {}
      }
    }
    ws.on('close', () => stop('clientClose'));
    ws.on('error', (e) => { L.warn('audio ws error', ip, e.message); stop('clientError'); });
    try {
      child = spawn('parec', [
        '--device=' + AUDIO_SOURCE, '--format=s16le', '--rate=' + rate, '--channels=' + channels,
      ], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) { LFILE.audio('SPAWN ERROR ' + e.message); L.error('audio spawn error', e.message); stop('spawnError'); return; }
    child.stdout.on('data', (d) => {
      if (closed || ws.readyState !== WebSocket.OPEN) return;
      chunks++;
      const peak = samplePeak(d);
      if (peak < AUDIO_SILENCE_THRESHOLD){ silentBytes += d.length; return; } // drop silence
      loudBytes += d.length;
      try { ws.send(d); } catch (e) { stop('sendError'); }
    });
    child.stderr.on('data', (d) => { LFILE.audio('parec stderr: ' + String(d).trim()); });
    child.on('error', (e) => { L.warn('audio child error', ip, e.message); stop('childError'); });
    child.on('exit', (code, sig) => {
      childExited = true;
      if (!closed && code !== 0){
        LFILE.audio('parec EXIT code=' + code + ' sig=' + sig + ' — is the audio service (nexdesk-audio) up?');
        L.warn('audio capture exited', ip, 'code=' + code, 'sig=' + sig);
        stop('captureExited');
      }
    });
    // periodic heartbeat so a half-open quiet stream is caught
    const hb = setInterval(() => {
      if (closed) return clearInterval(hb);
      LFILE.audio('heartbeat from ' + ip + ' loudKB=' + Math.round(loudBytes/1024) + ' silentKB=' + Math.round(silentBytes/1024) + ' chunks=' + chunks);
    }, 30000).unref();
    ws._nxaudioStop = stop;
    ws.on('close', () => { try { clearInterval(hb); } catch (e) {} });
  });
}

// Shared by both the HTTP and (optional) HTTPS listeners, so a viewer over
// either scheme can reach the same VNC bridge.
function handleUpgrade(req, socket, head) {
  const u = req.url || '';
  const ip = req.socket.remoteAddress || '?';
  const q = u.split('?')[0];
  if (q === BASE + '/audio') return handleAudioUpgrade(req, socket, head, ip);
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
// ===================== Upload injection bridge (Chrome CDP) =====================
// The virtual browser is a real Chrome on the virtual desktop, so a website's
// "choose file" normally opens the Linux file dialog *there* — which the visitor
// cannot use (their local files aren't on the desktop). Instead we drive Chrome
// through the DevTools Protocol: when Chrome asks for a file we swallow the
// dialog and tell the viewer. When the visitor picks an already-uploaded file
// (or uploads one on the spot), we set the page's <input type=file> directly
// from /home/nexdesk/MyFiles — no Linux window ever appears.
//
// Chrome must be running with --remote-debugging-port (see nexdesk-browser).
// We poll its /json/list for page targets and attach a per-page CDP socket that
// enables file-chooser interception. If CDP is unreachable we simply do nothing,
// so the browser keeps its normal native dialog (fail-open, safe).
const CDP_HTTP    = process.env.CHROME_CDP_HTTP || 'http://127.0.0.1:9223';
const CDP_POLL_MS = parseInt(process.env.CDP_POLL_MS || '2000', 10);
const CHOOSER_TTL_MS = parseInt(process.env.CHOOSER_TTL_MS || '180000', 10);

const cdp = {
  pages: new Map(),      // targetId -> { ws, id }
  pending: null,         // { pageId, backendNodeId, mode, at }
  enabled: false,
  _ttl: null,
};
function cdpJson(p){
  return new Promise((resolve) => {
    const r = http.get(CDP_HTTP + p, (s) => {
      let b = ''; s.on('data', (d) => { b += d; });
      s.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { resolve(null); } });
    });
    r.on('error', () => resolve(null));
    r.setTimeout(3000, () => { try { r.destroy(); } catch (e) {} resolve(null); });
  });
}
function cdpCancelPending(why){
  const p = cdp.pending;
  if (cdp._ttl){ clearTimeout(cdp._ttl); cdp._ttl = null; }
  cdp.pending = null;
  if (!p) return;
  const page = cdp.pages.get(p.pageId);
  if (page && page.ws && page.ws.readyState === WebSocket.OPEN){
    try { page.ws.send(JSON.stringify({ id: Date.now(), method: 'Page.handleFileChooser', params: { action: 'cancel' } })); } catch (e) {}
  }
  LFILE.files('CHOP cancel (' + (why || 'timeout') + ')');
  L.info('file chooser cancelled', why || 'timeout');
}
function setPendingChooser(pageId, params){
  cdpCancelPending('superseded');           // resolve any earlier pending dialog first
  cdp.pending = { pageId, backendNodeId: params.backendNodeId, mode: params.mode, at: Date.now() };
  cdp._ttl = setTimeout(() => cdpCancelPending('timeout'), CHOOSER_TTL_MS);
  if (cdp._ttl.unref) cdp._ttl.unref();
  LFILE.files('CHOP open (intercept) backendNodeId=' + params.backendNodeId + ' mode=' + params.mode);
  L.info('file chooser intercepted — waiting for viewer to pick a file');
}
// Send one CDP command and resolve with Chrome's full reply (success or error).
// This lets us WAIT for the outcome instead of assuming a fire-and-forget send worked.
function cdpCommand(page, method, params, timeoutMs){
  return new Promise((resolve) => {
    if (!page || !page.ws || page.ws.readyState !== WebSocket.OPEN){
      resolve({ error: { message: 'no target' } }); return;
    }
    const id = ++page.seq;
    const timer = setTimeout(() => { page.reqs.delete(id); resolve({ error: { message: 'cdp timeout' } }); }, timeoutMs || 6000);
    page.reqs.set(id, (m) => { clearTimeout(timer); resolve(m); });
    try { page.ws.send(JSON.stringify({ id, method, params: params || {} })); }
    catch (e) { clearTimeout(timer); page.reqs.delete(id); resolve({ error: { message: 'cdp send failed' } }); }
  });
}
// Locate the page's live file input (the one a user would click) and return its objectId.
async function cdpDiscoverInput(page){
  const expr = `(function(){
    var all = Array.prototype.slice.call(document.querySelectorAll('input[type=file]'));
    if (!all.length) return null;
    var nonFolder = all.filter(function(e){ return !e.hasAttribute('webkitdirectory') && !e.hasAttribute('directory'); });
    var pool = nonFolder.length ? nonFolder : all;
    var hinted = pool.filter(function(e){ return /file|upload|input|browse/i.test((e.id||'') + ' ' + (e.name||'')); });
    var sel = (hinted.length ? hinted : pool);
    return sel[sel.length - 1];
  })()`;
  const r = await cdpCommand(page, 'Runtime.evaluate', { expression: expr }, 6000);
  return (r && r.result && r.result.result && r.result.result.objectId) ? r.result.result.objectId : null;
}
// Prove the file really landed: ask the page whether any live file input now
// holds our file. Chrome can answer "success" for a stale backendNodeId that
// after a navigation points at a different node, so a bare success reply is
// not proof — this verification is.
async function cdpHasFile(page, fname){
  const r = await cdpCommand(page, 'Runtime.evaluate', {
    expression: '(function(){' +
      'var want=' + JSON.stringify(fname) + ';' +
      'var els=Array.prototype.slice.call(document.querySelectorAll("input[type=file]"));' +
      'for(var i=0;i<els.length;i++){' +
      '  var fl=els[i].files;' +
      '  if(fl){ for(var j=0;j<fl.length;j++){ if(fl[j].name===want) return true; } }' +
      '}' +
      'return false;' +
    '})()',
    returnByValue: true,
  }, 4000);
  return !!(r && r.result && r.result.result && r.result.result.value === true);
}
// Deliver the chosen file into the site that opened the chooser. Instead of
// trusting one node reference blindly, this waits for Chrome's actual reply,
// retries with a freshly-located input when the recorded one has gone stale,
// and only reports success once a live input really accepted the file — so the
// viewer is never told "sent" when nothing actually landed.
async function cdpInject(fullPath){
  const p = cdp.pending;
  if (cdp._ttl){ clearTimeout(cdp._ttl); cdp._ttl = null; }
  cdp.pending = null;
  if (!p) return { ok:false, error:'no pending file request' };
  const page = cdp.pages.get(p.pageId);
  if (!page || !page.ws || page.ws.readyState !== WebSocket.OPEN)
    return { ok:false, error:'The browser page changed — please click the site’s “choose file” again.' };
  const fname = path.basename(fullPath);
  const accepted = (reply) => !!reply && !reply.error &&
    !(reply.result && reply.result.exceptionDetails) &&
    !(reply.result && reply.result.exception);

  let injected = false, lastErr = null;

  // Wait for the page to reflect the change, then CONFIRM the file is really
  // there (see cdpHasFile) before trusting the reply. A stale backendNodeId
  // can come back "success" after the site navigated and reuse a new node.
  const settle = async (errLabel) => {
    await new Promise((rs) => setTimeout(rs, 350));
    if (await cdpHasFile(page, fname)) return true;
    lastErr = errLabel;
    return false;
  };

  // Primary: the exact input Chrome associated with the open chooser.
  if (p.backendNodeId != null){
    const r = await cdpCommand(page, 'DOM.setFileInputFiles',
      { backendNodeId: p.backendNodeId, files: [fullPath] }, 8000);
    if (accepted(r)) injected = await settle('input no longer valid (page changed?)');
    else lastErr = (r && r.error && r.error.message) || 'input no longer available';
    L.debug('inject primary', fname, JSON.stringify(r).slice(0,120));
  }

  // Repair: an SPA may re-render its control between the click and the moment
  // you press Send, invalidating the recorded node. Re-locate the input that is
  // actually live in the page right now and place the file there.
  if (!injected){
    try {
      const objectId = await cdpDiscoverInput(page);
      if (objectId){
        const r = await cdpCommand(page, 'DOM.setFileInputFiles', { objectId, files: [fullPath] }, 8000);
        if (accepted(r)) injected = await settle('input not writable');
        else lastErr = (r && r.error && r.error.message) || 'input not writable';
        L.debug('inject fallback', fname, JSON.stringify(r).slice(0,120));
      } else lastErr = 'no file input found on the page';
    } catch (e) { lastErr = (e && e.message) || 'discovery failed'; }
  }

  if (!injected){
    LFILE.files('INJECT FAIL name=' + fname + ' page=' + p.pageId + ' reason=' + (lastErr || 'unknown'));
    L.info('file injection FAILED', fname, lastErr);
    return { ok:false, error:'The site did not accept the file (' + (lastErr || 'unknown') + '). If it needs a real interaction, use its own upload — otherwise choose a different site.' };
  }

  LFILE.files('INJECT name=' + fname + ' page=' + p.pageId + ' mode=' + p.mode);
  L.info('file injected into virtual page', fname);
  return { ok:true };
}
async function cdpPoll(){
  const list = await cdpJson('/json/list');
  if (!Array.isArray(list)) return;
  const pages = list.filter((t) => t && t.type === 'page' && t.webSocketDebuggerUrl && /^ws/.test(t.webSocketDebuggerUrl));
  const seen = new Set();
  for (const t of pages){
    seen.add(t.id);
    if (cdp.pages.has(t.id)) continue;
    let ws;
    try { ws = new WebSocket(t.webSocketDebuggerUrl); } catch (e) { continue; }
    const rec = { id: t.id, ws, reqs: new Map(), seq: 1000 };
    ws.on('open', () => {
      cdp.enabled = true;
      try {
        ws.send(JSON.stringify({ id: ++rec.seq, method: 'DOM.enable' }));
        ws.send(JSON.stringify({ id: ++rec.seq, method: 'Page.enable' }));
        ws.send(JSON.stringify({ id: ++rec.seq, method: 'Runtime.enable' }));
        ws.send(JSON.stringify({ id: ++rec.seq, method: 'Page.setInterceptFileChooserDialog', params: { enabled: true } }));
      } catch (e) {}
      L.debug('cdp attached page target', t.id);
    });
    ws.on('message', (data) => {
      let m = null; try { m = JSON.parse(String(data)); } catch (e) { return; }
      // Route awaited command replies (see cdpCommand) before handling events.
      if (m && m.id && rec.reqs.has(m.id)) {
        const fn = rec.reqs.get(m.id); rec.reqs.delete(m.id); fn(m); return;
      }
      if (m && m.method === 'Page.fileChooserOpened') setPendingChooser(t.id, m.params || {});
    });
    ws.on('close', () => { cdp.pages.delete(t.id); if (!cdp.pages.size) cdp.enabled = false; });
    ws.on('error', () => { try { ws.close(); } catch (e) {} });
    cdp.pages.set(t.id, rec);
  }
  for (const id of Array.from(cdp.pages.keys())){
    if (!seen.has(id)){ const r = cdp.pages.get(id); if (r && r.ws){ try { r.ws.close(); } catch (e) {} } cdp.pages.delete(id); }
  }
}
setInterval(cdpPoll, CDP_POLL_MS).unref();
cdpPoll();

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
