#!/usr/bin/env node
// phone-drop server: streams files named in a manifest, with Range (resumable) support.
// Usage: node serve.js            (reads PHONE_DROP_PORT, PHONE_DROP_STATE_DIR)
'use strict';
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = parseInt(process.env.PHONE_DROP_PORT || '8139', 10);
const STATE = process.env.PHONE_DROP_STATE_DIR || path.join(os.homedir(), '.phone-drop');
const MANIFEST = path.join(STATE, 'manifest.json');

const TYPES = {
  '.pdf': 'application/pdf', '.zip': 'application/zip', '.gz': 'application/gzip',
  '.tar': 'application/x-tar', '.7z': 'application/x-7z-compressed', '.rar': 'application/vnd.rar',
  '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.mkv': 'video/x-matroska', '.webm': 'video/webm',
  '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.wav': 'audio/wav', '.flac': 'audio/flac',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif',
  '.webp': 'image/webp', '.heic': 'image/heic', '.svg': 'image/svg+xml',
  '.apk': 'application/vnd.android.package-archive', '.ipa': 'application/octet-stream',
  '.txt': 'text/plain; charset=utf-8', '.md': 'text/plain; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8', '.json': 'application/json', '.html': 'text/html; charset=utf-8',
  '.doc': 'application/msword', '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel', '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint', '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.dmg': 'application/x-apple-diskimage', '.iso': 'application/x-iso9660-image',
};
function typeFor(name) { return TYPES[path.extname(name).toLowerCase()] || 'application/octet-stream'; }
function esc(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function fmtSize(n) { const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; } return (i ? n.toFixed(1) : n) + ' ' + u[i]; }
function loadManifest() { try { return JSON.parse(fs.readFileSync(MANIFEST, 'utf8')); } catch { return null; } }

const CSS = 'body{margin:0;font:16px/1.5 -apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;background:#f6f6f4;color:#14161a;padding:24px 16px}' +
  'h1{font-size:20px;margin:0 0 4px}.sub{color:#6b7076;font-size:13px;margin:0 0 18px}' +
  '.list{display:grid;gap:10px;max-width:560px}' +
  '.item{display:flex;justify-content:space-between;gap:12px;align-items:center;text-decoration:none;color:inherit;background:#fff;border:1px solid #e2e0d8;border-radius:12px;padding:14px 16px}' +
  '.item:active{transform:scale(.99)}.n{font-weight:600;word-break:break-all}.s{color:#6b7076;font-size:13px;white-space:nowrap}' +
  '.tip{color:#6b7076;font-size:13px;margin-top:20px}' +
  '@media (prefers-color-scheme:dark){body{background:#17181b;color:#eef0f2}.item{background:#202226;border-color:#33363b}.s,.tip,.sub{color:#9aa0a6}}';

function indexPage(m) {
  const items = m.files.map((f, i) =>
    '<a class="item" href="/' + m.token + '/' + i + '" download="' + esc(f.name) + '">' +
    '<span class="n">' + esc(f.name) + '</span><span class="s">' + fmtSize(f.size) + '</span></a>').join('\n');
  const totalBytes = m.files.reduce((a, f) => a + f.size, 0);
  return '<!doctype html><html lang="zh"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>文件下载</title><style>' + CSS + '</style></head><body>' +
    '<h1>&#128229; 点一下下载</h1>' +
    '<p class="sub">' + m.files.length + ' 个文件 · ' + fmtSize(totalBytes) + ' · 支持断点续传</p>' +
    '<div class="list">' + items + '</div>' +
    '<p class="tip">下载完成后可以让助手停止分享。</p></body></html>';
}

function contentDisposition(name) {
  const ascii = String(name).replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  return 'attachment; filename="' + ascii + '"; filename*=UTF-8\'\'' + encodeURIComponent(name);
}
function streamFile(req, res, f) {
  let st;
  try { st = fs.statSync(f.path); } catch { res.writeHead(410, { 'content-type': 'text/plain' }); return res.end('file is gone'); }
  const total = st.size;
  const base = {
    'content-type': f.type || typeFor(f.name),
    'accept-ranges': 'bytes',
    'last-modified': st.mtime.toUTCString(),
    'content-disposition': contentDisposition(f.name),
    'cache-control': 'no-store',
  };
  const range = req.headers.range;
  if (range) {
    const rm = /^bytes=(\d*)-(\d*)$/.exec(String(range).trim());
    if (rm) {
      let start = rm[1] === '' ? null : parseInt(rm[1], 10);
      let end = rm[2] === '' ? null : parseInt(rm[2], 10);
      if (start === null && end !== null) { start = Math.max(0, total - end); end = total - 1; }
      if (start === null || isNaN(start)) start = 0;
      if (end === null || isNaN(end) || end >= total) end = total - 1;
      if (start > end || start >= total) { res.writeHead(416, { 'content-range': 'bytes */' + total }); return res.end(); }
      const h = Object.assign({}, base, { 'content-range': 'bytes ' + start + '-' + end + '/' + total, 'content-length': String(end - start + 1) });
      res.writeHead(206, h);
      if (req.method === 'HEAD') return res.end();
      const s = fs.createReadStream(f.path, { start, end });
      s.on('error', () => res.destroy());
      res.on('close', () => { if (!res.writableEnded) s.destroy(); });
      s.pipe(res);
      return;
    }
  }
  res.writeHead(200, Object.assign({}, base, { 'content-length': String(total) }));
  if (req.method === 'HEAD') return res.end();
  const s = fs.createReadStream(f.path);
  s.on('error', () => res.destroy());
  res.on('close', () => { if (!res.writableEnded) s.destroy(); });
  s.pipe(res);
}

function handle(req, res) {
  try {
  let p;
  try { p = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); } catch { p = req.url; }
  const m = loadManifest();
  if (!m) { res.writeHead(503, { 'content-type': 'text/plain; charset=utf-8' }); return res.end('no active drop'); }
  if (p === '/' || p === '/' + m.token || p === '/' + m.token + '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    return res.end(indexPage(m));
  }
  const mm = new RegExp('^/' + m.token.replace(/[^a-zA-Z0-9]/g, '') + '/(\\d+)$').exec(p);
  if (mm) {
    const f = m.files[parseInt(mm[1], 10)];
    if (!f) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('not found'); }
    return streamFile(req, res, f);
  }
  res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
  res.end('not found');
  } catch (e) {
    console.error('request error', e && e.message);
    try { if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' }); res.end('server error'); } catch (_) {}
  }
}
const server = http.createServer(handle);
server.listen(PORT, '127.0.0.1', () => console.log('phone-drop server listening on 127.0.0.1:' + PORT));
