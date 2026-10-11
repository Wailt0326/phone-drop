# Troubleshooting

Everything here was hit on a real end-to-end run (a 1.87 GB zip from a Windows
desktop through WSL2 to an iPhone/Android browser). Each entry names the symptom,
the cause, and the fix that is now in the code.

## 1. Server crashes on a non-ASCII filename (fixed)

**Symptom:** the index page loads but the file returns an empty reply; the unit log
shows `ERR_INVALID_CHAR` and the service exits.

**Cause:** Node rejects non-ASCII bytes in an HTTP header value, and a Chinese file
name was put straight into `Content-Disposition`.

**Fix:** `serve.js` now emits an RFC 5987 header — an ASCII-sanitised
`filename="…"` plus `filename*=UTF-8''<percent-encoded>` — and the request handler is
wrapped in try/catch so one bad request can never take the server down.

## 2. Printing a URL that belongs to the previous run (fixed)

**Symptom:** `drop.sh start` prints a `trycloudflare.com` URL, and it answers 530.

**Cause:** a quick-tunnel hostname is random per run, and the lookup grepped the
whole unit journal — so it returned the previous run's URL.

**Fix:** the lookup only reads journal lines **since the tunnel unit's current
`ActiveEnterTimestamp`** (`drop.sh origin`). If the new URL has not appeared yet,
`start` prints "URL not ready yet" instead of a stale link.

## 3. cloudflared cannot reach the edge: QUIC blocked

**Symptom:** `Failed to dial a quic connection ... timeout`, retrying forever; the
public URL answers 530.

**Cause:** UDP/QUIC to the edge is blocked on some networks.

**Fix:** the tunnel now runs with `--protocol http2` by default
(`PHONE_DROP_CF_PROTOCOL` overrides it). Verify with
`journalctl --user -u phone-drop-tunnel | grep 'Registered tunnel connection'`.

## 4. cloudflared cannot reach the edge: fake-IP DNS

**Symptom:** same 530, but the log shows the edge IP as `198.18.0.x`, and
`getent hosts region1.v2.argotunnel.com` returns something in `198.18.0.0/15`.
**Reproduce the cause:** `curl -s 'https://dns.google/resolve?name=region1.v2.argotunnel.com&type=A'`
returns a real `198.41.192.x` address, so the system resolver — not the network — is lying.

**Cause:** a Windows proxy/VPN in fake-IP mode owns DNS for WSL and hands out
unroutable placeholder addresses. `/etc/resolv.conf` is a generated symlink owned by
root, so it cannot be fixed from inside.

**Fix (opt-in):** `PHONE_DROP_CF_HOSTS_FIX=1` makes `start` write
`~/.phone-drop/hosts` with the real edge IPs fetched over DoH, and run cloudflared
through `scripts/tunnel_wrap.sh`, which bind-mounts that file over `/etc/hosts`
inside a user+mount namespace (no root needed).

```bash
PHONE_DROP_CF_HOSTS_FIX=1 bash {baseDir}/scripts/drop.sh start <file>
```

Note: this fixes *name resolution*. If the edge IP range itself is unreachable
(`curl --resolve region1.v2.argotunnel.com:443:198.41.192.167 https://region1.v2.argotunnel.com/`
returns `000` while a normal Cloudflare IP returns `200`), the network is blocking it —
see §5.

## 5. The edge range is blocked outright

**Symptom:** the hosts fix is applied, cloudflared now logs real `198.41.192.x`
addresses, but still `TLS handshake with edge error: EOF`; a `curl` to that IP is `000`.

**Cause:** the egress path (usually the same proxy/VPN) is dropping that range. On
this host it worked, broke for ~25 minutes, then recovered on its own — most likely
the proxy/VPN was toggled or restarted.

**Fix:** restore/restart the proxy or VPN (or turn it off, if the direct route
works), then `systemctl --user restart phone-drop-tunnel.service`. If both foreign
and direct routes stay blocked, use a **domestic** relay instead — see
`references/tunnels.md`.

## 6. A domestic relay answers `503 客户端未连接`

Observed with Oray 花生壳 (`hsk-cli`) on this host: small responses (a 1 KB range)
worked, anything larger returned `503` with a "client not connected" page, and the
account's existing tunnel returned `503` too — i.e. the relay/account was the
problem, not the skill. Check the provider's own tunnel before blaming the client.

## 7. Reading from `/mnt/c` is fine — do not copy GB-scale files

Serving straight from `/mnt/c/Users/.../Desktop` measured ~67 MB/s on this host, far
above any tunnel, so the no-copy manifest design is the right default. If the phone
cannot open the link but the host can, that is the tunnel or the phone's network,
never the disk.

## 8. `verify` said `public=000` while the link worked

**Cause:** the host resolver negative-cached the brand-new tunnel hostname seconds
after start.

**Fix:** `verify` falls back to a Cloudflare edge IP
(`PHONE_DROP_VERIFY_IP`, default `104.16.231.132`) **for the check only**; the URL
handed to the user is unchanged. A phone resolves the name independently.
