# Fallback tunnels for phone-drop

Default is the **cloudflared quick tunnel** (`PHONE_DROP_TUNNEL=cloudflared`): no
account, measured ~2-5 MB/s here, but its `*.trycloudflare.com` hostnames change on
every restart and Cloudflare can be blocked on some mainland-China mobile networks.

Switch by re-running `start` with `PHONE_DROP_TUNNEL=<name>`; only the tunnel unit's
ExecStart changes, the file server stays the same.

Measured on this host, 50 MB file, from the host itself:

| tunnel | speed | hostname | notes |
| --- | --- | --- | --- |
| cloudflared quick | ~2–5 MB/s | random `*.trycloudflare.com` | default; needs Cloudflare edge reachable |
| serveo (fixed name) | ~20–40 KB/s | `<sub>.serveousercontent.com` | stable URL; far too slow for large files |
| localhost.run | ~24 KB/s | random `*.lhr.life` | slow; changes on restart |

## serveo (fixed subdomain, stable URL)

```
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -R wailt-drop:80:127.0.0.1:8139 serveo.net
```

The chosen subdomain works only once this host's SSH key is registered at serveo.
A fixed name keeps its URL across reconnects; a random one changes. Do not start two
tunnels with the same fixed name at once — they fight over the route and answer 502.

## localhost.run (no account)

```
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -R 80:127.0.0.1:8139 nokey@localhost.run
```

## Oray 花生壳 hsk-cli (best for mainland-China phones)

Installed at `~/.hsk/bin/hsk-cli-linux-amd64-v0.7.25`. Domestic service, so its
domain resolves on Chinese carrier networks where the foreign tunnels above may not.

```bash
hsk-cli tunnel -ip 127.0.0.1 -port 8139 --format json
```

It stays in the foreground (use it as the unit's ExecStart) and, on a headless host,
prints a **claim link** (with a verify_code) plus a device code. Relay both to the
operator immediately — the anonymous claim window is about 120 s. The public URL
appears only after the operator claims it in a browser.

## Rules for every tunnel

- The host resolver sometimes **negative-caches a brand-new tunnel hostname**, so a
  `curl` from this host can report `000` right after start while the phone resolves
  fine. `drop.sh verify` retries against a Cloudflare edge IP
  (`PHONE_DROP_VERIFY_IP`, default `104.16.231.132`) for the check only.
- Verify the **public** URL, not just loopback, before handing the link out.
- Free tunnels drop on their own; the unit's `Restart=always` reconnects. A random
  name changes on reconnect, a serveo fixed name does not.
- Persist tunnels as systemd **user** units — background `exec` jobs are reaped.
- Never `pkill -f <pattern>` in the same shell command that mentions the matching
  process: the pattern matches the shell's own command line and kills the chain.
