#!/usr/bin/env node
'use strict';
const fs = require('fs'), path = require('path'), os = require('os'), crypto = require('crypto');
const STATE = process.env.PHONE_DROP_STATE_DIR || path.join(os.homedir(), '.phone-drop');
const args = process.argv.slice(2);
if (!args.length) { console.error('usage: make_manifest.js <file-or-dir> [...]'); process.exit(2); }
const files = [];
function add(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) { for (const e of fs.readdirSync(p).sort()) add(path.join(p, e)); }
  else if (st.isFile()) { files.push({ name: path.basename(p), path: fs.realpathSync(p), size: st.size }); }
}
for (const a of args) { if (!fs.existsSync(a)) { console.error('not found: ' + a); process.exit(1); } add(path.resolve(a)); }
const token = crypto.randomBytes(12).toString('hex');
const manifest = { token, createdAt: new Date().toISOString(), files };
fs.mkdirSync(STATE, { recursive: true });
fs.writeFileSync(path.join(STATE, 'manifest.json'), JSON.stringify(manifest, null, 2));
fs.writeFileSync(path.join(STATE, 'token'), token);
console.log(JSON.stringify({ token, count: files.length, bytes: files.reduce((a, f) => a + f.size, 0) }));
