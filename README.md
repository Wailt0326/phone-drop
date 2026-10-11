# phone-drop

An [OpenClaw](https://openclaw.ai) **AgentSkill** that sends files — including large ones — from a Linux/WSL host to a phone (iPhone **or** Android) over the internet, through a link you just tap in a browser.

No app, no account, no same-Wi-Fi requirement. Built for large files, and hardened by a real 1.87 GB transfer.

## Why it exists

Every "transfer a file to my phone" path breaks on big files: cloud drives need accounts and quota, AirDrop doesn't speak Linux, and a plain `python -m http.server` behind a fast tunnel still can't resume a dropped download. `phone-drop` fixes the three things that actually matter:

1. **No copy** — files are served in place from a manifest (real path + size). A 4 GB file starts serving instantly and uses zero extra disk.
2. **Resumable** — the bundled Node server implements HTTP **Range / 206**, so a dropped mobile connection resumes instead of restarting.
3. **A fast tunnel by default** — a cloudflared quick tunnel (no account) measured **~3.5–4.8 MB/s** here, versus **~20–40 KB/s** for serveo in the same test.

## Features

- iPhone & Android, any browser — tap the file, "Save to Files" / "Save to Downloads"
- Random token path (`/<token>/`) so the URL is not guessable
- Mobile-friendly download page (light/dark), file names + sizes, **非 ASCII 文件名安全** (RFC 5987)
- systemd **user** units (survive the shell, auto-restart)
- `stop` tears everything down and clears the manifest
- Tunnel fallbacks: cloudflared (default), serveo, localhost.run, and the domestic Oray 花生壳 `hsk-cli` for mainland-China phones

## Requirements

- Linux with **systemd user services** (`systemctl --user`)
- **Node.js** ≥ 16 (`node`)
- **cloudflared** at `~/.local/bin/cloudflared` for the default tunnel (or use `serveo`/`lhr` — those only need `ssh`)
- `curl` (verification)

## Install

```bash
git clone https://github.com/Wailt0326/phone-drop.git \
  ~/.openclaw/workspace/skills/phone-drop
```

OpenClaw discovers it as a skill on the next turn.

## Usage

```bash
S=~/.openclaw/workspace/skills/phone-drop/scripts/drop.sh

# 1. stage files and start the server + tunnel
bash $S start ~/Videos/holiday.mp4 ~/docs/report.pdf

# 2. fetch the public URL (a cloudflared URL takes ~5-10s to appear)
bash $S url

# 3. verify before sharing -> "local=200 public=200" + url=
bash $S verify

# 4. share the printed URL; on the phone, tap the file to download

# 5. tear down and clear the manifest
bash $S stop
```

A directory argument is expanded to its files (recursively). `start` never prints a URL belonging to a previous run: if the new tunnel has not published one yet it says so and you call `url`.

### Options

| Env var | Default | Meaning |
| --- | --- | --- |
| `PHONE_DROP_PORT` | `8139` | loopback port for the file server |
| `PHONE_DROP_TUNNEL` | `cloudflared` | `cloudflared` \| `serveo` \| `lhr` |
| `PHONE_DROP_CF_PROTOCOL` | `http2` | cloudflared transport (QUIC is blocked on some networks) |
| `PHONE_DROP_CF_HOSTS_FIX` | `0` | `1` = work around fake-IP DNS (198.18.x) behind a proxy/VPN |
| `PHONE_DROP_SUBDOMAIN` | `wailt-drop` | serveo fixed subdomain (set your own) |
| `PHONE_DROP_STATE_DIR` | `~/.phone-drop` | manifest + token location |
| `PHONE_DROP_NODE` | auto | node binary |
| `PHONE_DROP_CLOUDFLARED` | `~/.local/bin/cloudflared` | cloudflared binary |

## How it works

```
phone /
 /<token>/            -> download page (file list + sizes, light/dark)
 /<token>/<n>         -> file n, streamed with Range/206 support

  (127.0.0.1:8139)  <-- systemd user unit: phone-drop.service  (scripts/serve.js)
        ^
        |  cloudflared quick tunnel (--protocol http2)
        v
  (public)  https://<random>.trycloudflare.com  <-- phone-drop-tunnel.service
```

- Both processes run as **systemd user units**; background `exec` jobs get reaped and the link dies with them.
- `scripts/make_manifest.js` writes `~/.phone-drop/manifest.json`; the server never exposes an arbitrary directory, only the files named there.
- `scripts/drop.sh verify` also reports whether the tunnel reached the Cloudflare edge, and falls back to an edge IP when the host resolver negative-caches a brand-new tunnel name.

## Measured speeds (from the host itself)

| tunnel | speed | hostname |
| --- | --- | --- |
| **cloudflared quick** | **~3.5–4.8 MB/s** | random `*.trycloudflare.com` |
| serveo (fixed name) | ~20–40 KB/s | `<sub>.serveousercontent.com` |
| localhost.run | ~24 KB/s | random `*.lhr.life` |

The same host pulled **9.3 MB/s** from a domestic mirror and **67 MB/s** from `/mnt/c`, so the free relay was the bottleneck, not the disk or the uplink. A 1.87 GB file transfers in roughly **9–10 minutes**.

## Troubleshooting

Real failures hit in production, with causes and fixes, are written up in
[`references/troubleshooting.md`](references/troubleshooting.md): non-ASCII filename crash,
a stale URL from a previous run, QUIC blocked, fake-IP DNS behind a Windows proxy/VPN,
an outright-blocked edge range, and a domestic relay answering `503`.

## Security

- The URL is **public** while running; the random token is its only secret. Share it only with the intended recipient, and `stop` when done.
- The file server binds to `127.0.0.1`; only the tunnel exposes it.
- The manifest names only the files you passed in — nothing else on disk is reachable.
- A cloudflared quick tunnel is account-less (Cloudflare's terms: no uptime guarantee, meant for experiments).

## 中文说明

一个 OpenClaw 技能：把本机（Linux/WSL）的文件——包括大文件——通过一个**浏览器点的链接**传到手机（iPhone / 安卓都行），不需要装 App、不需要同一个 WiFi。

- **不复制文件**：原地读取（实测 /mnt/c 读取 67 MB/s），4GB 的文件秒级开服、不占额外磁盘
- **支持断点续传**：手机断网后重新点一下就接着下（HTTP Range / 206）
- **默认走 cloudflared 快隧道**：实测约 3.5–4.8 MB/s（serveo 只有约 20–40 KB/s）
- **中文文件名安全**：下载头用 RFC 5987 编码，不会再让服务崩溃
- 随机 token 路径、随用随停、`stop` 一键清理

用法见上面的 `Usage`（`drop.sh start / url / verify / stop`）。国内移动网络若打不开 `trycloudflare.com`，可用 `references/tunnels.md` 里的花生壳方案；遇到的坑与解决见 `references/troubleshooting.md`。

## License

MIT — see [LICENSE](LICENSE).
