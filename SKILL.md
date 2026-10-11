---
name: phone-drop
description: "Send files - including large ones (GB-scale, videos, app packages) - from this host to a phone (iPhone or Android) over the internet, through a browser link the user taps. Use when the user asks to transfer, send, or download a file onto their phone from anywhere (not just the same Wi-Fi), or wants a tap-to-download link. Files are served in place (no copy) with HTTP Range support for resumable downloads, behind a random token, on a temporary cloudflared quick tunnel; stop tears it down."
---

# Phone Drop

Put a file (or folder) onto a phone via a link the user taps in Safari/Chrome.
Works for iPhone and Android, from outside the local network, and is built for
**large files**.

## Architecture

- **No copy**: `scripts/make_manifest.js` writes `~/.phone-drop/manifest.json`
  holding each file's real absolute path + size. Nothing is duplicated, so a
  4 GB file starts serving in milliseconds and uses no extra disk.
- **Resumable server**: `scripts/serve.js` (Node, no deps) streams each file and
  implements HTTP **Range / 206**, so a dropped mobile connection resumes instead
  of restarting. Bound to `127.0.0.1` only.
- **Public tunnel**: a systemd **user** unit runs a cloudflared **quick tunnel**
  (no account, measured ~2-5 MB/s here) and prints a
  `https://<name>.trycloudflare.com` URL in the journal.
- **Token**: the URL path is `/<random-token>/`; the index and files live under it.
- `stop` stops both units and deletes the manifest.

Both processes are systemd **user** units because background `exec` jobs are
reaped when the shell exits (`nohup` dies with the link).

## 1. Start

```bash
bash {baseDir}/scripts/drop.sh start <file-or-dir> [more...]
```

Prints the manifest summary on stderr. A cloudflared URL takes ~5-10 s to appear,
so if stdout says "URL not ready", fetch it in the next step.
**Done when:** `drop.sh url` prints a `https://…trycloudflare.com/<token>/` URL.

## 2. Verify before handing it over

```bash
bash {baseDir}/scripts/drop.sh verify     # -> local=200 public=200  + url=
```

If public is `000`, wait ~10 s and retry (tunnel handshake, or the host resolver
negative-caching the brand-new name — `verify` falls back to a Cloudflare edge IP
for the check only). Do not hand out the link until `public=200`.

## 3. Hand the link to the user (privately)

Send the printed URL to the intended person only. On the phone: open the link,
tap the file, then **Save to Files / Downloads**. Large downloads can continue in
the background; if the connection drops, tapping again resumes (Range).

## 4. Stop when done

```bash
bash {baseDir}/scripts/drop.sh stop        # stops units + clears the manifest
```

Do this once the user confirms the download; the URL is public while running.

## Options

| Env var | Default | Meaning |
| --- | --- | --- |
| `PHONE_DROP_PORT` | `8139` | loopback port |
| `PHONE_DROP_TUNNEL` | `cloudflared` | `cloudflared` \| `serveo` \| `lhr` |
| `PHONE_DROP_SUBDOMAIN` | `wailt-drop` | serveo fixed subdomain |
| `PHONE_DROP_STATE_DIR` | `~/.phone-drop` | manifest + token |
| `PHONE_DROP_NODE` | auto | node binary |
| `PHONE_DROP_CF_PROTOCOL` | `http2` | cloudflared transport; QUIC is blocked on some networks |
| `PHONE_DROP_CF_HOSTS_FIX` | `0` | set `1` when a proxy/VPN gives DNS fake IPs (198.18.x) |

## Large files / tunnel choice

Measured on this host for a 50 MB file:

| tunnel | speed | note |
| --- | --- | --- |
| **cloudflared quick** | **~2–5 MB/s** | default; random URL; trycloudflare.com may be blocked on some mainland-China mobile networks |
| serveo (fixed name) | ~20–40 KB/s | **unusable for large files**; keep for tiny files / stable URL |
| localhost.run | ~24 KB/s | same caveat |

If the phone cannot open the trycloudflare link, switch `PHONE_DROP_TUNNEL` — see
`references/tunnels.md` (including the domestic Oray 花生壳 `hsk-cli` for
mainland-China phones).

## Troubleshooting

See `references/troubleshooting.md` for the failures seen in real use and their
fixes — non-ASCII filenames, a stale URL from a previous run, QUIC blocked
(`--protocol http2` is already the default), fake-IP DNS behind a Windows
proxy/VPN (`PHONE_DROP_CF_HOSTS_FIX=1`), and an edge range that is blocked outright.
`drop.sh verify` prints whether the tunnel actually reached the Cloudflare edge.

## Notes

- The URL is public while running; the random token is its only secret.
- Non-ASCII file names (中文, emoji, …) are safe: the download header is RFC 5987
  encoded and the request handler can no longer crash the server.
- iOS Safari saves to Files; Android Chrome saves to Downloads. Both handle
  multi-GB files with Range.
- Keep a large download's tab in the foreground at first; iOS may suspend
  background tabs.
