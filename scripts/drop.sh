#!/usr/bin/env bash
# phone-drop - send files (incl. large ones) to a phone via a browser link
#   drop.sh start <path> [path...]   stage a manifest, start server+tunnel, print URL if ready
#   drop.sh url                      print the current public URL (once the tunnel is up)
#   drop.sh verify                   check loopback + public reachability, print the URL
#   drop.sh status                   unit state + current manifest
#   drop.sh stop                     stop both units and clear the manifest
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${PHONE_DROP_STATE_DIR:-$HOME/.phone-drop}"
PORT="${PHONE_DROP_PORT:-8139}"
SUBDOMAIN="${PHONE_DROP_SUBDOMAIN:-wailt-drop}"
TUNNEL="${PHONE_DROP_TUNNEL:-cloudflared}"
CF_PROTO="${PHONE_DROP_CF_PROTOCOL:-http2}"
HOSTS_FIX="${PHONE_DROP_CF_HOSTS_FIX:-0}"
NODE="${PHONE_DROP_NODE:-$(command -v node || echo /usr/bin/node)}"
CF="${PHONE_DROP_CLOUDFLARED:-$HOME/.local/bin/cloudflared}"
UNIT_SERVER="phone-drop.service"
UNIT_TUNNEL="phone-drop-tunnel.service"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

die(){ echo "phone-drop: $*" >&2; exit 1; }
token(){ cat "$STATE_DIR/token" 2>/dev/null || true; }
unit_started(){ systemctl --user show "$UNIT_TUNNEL" -p ActiveEnterTimestamp --value 2>/dev/null || true; }

# Resolve the real Cloudflare tunnel-edge IPs over DoH. Needed only when a host
# proxy/VPN answers DNS with unroutable fake IPs (198.18.0.0/15) for *.argotunnel.com.
update_cf_hosts(){
  local f="$STATE_DIR/hosts" r1 r2
  r1=$(curl -s -m 6 'https://dns.google/resolve?name=region1.v2.argotunnel.com&type=A' 2>/dev/null | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4 || true)
  r2=$(curl -s -m 6 'https://dns.google/resolve?name=region2.v2.argotunnel.com&type=A' 2>/dev/null | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4 || true)
  [ -n "$r1" ] || { echo "phone-drop: DoH lookup failed; leaving hosts file alone" >&2; return 0; }
  { echo "127.0.0.1 localhost"
    echo "::1 localhost"
    for i in $r1; do echo "$i region1.v2.argotunnel.com"; done
    for i in $r2; do echo "$i region2.v2.argotunnel.com"; done
  } > "$f"
}

tunnel_exec(){
  local cf="$CF tunnel --url http://127.0.0.1:${PORT} --no-autoupdate"
  [ -n "$CF_PROTO" ] && cf="$cf --protocol $CF_PROTO"
  case "$TUNNEL" in
    cloudflared)
      if [ "$HOSTS_FIX" = "1" ] && [ -x "$SKILL_DIR/scripts/tunnel_wrap.sh" ] && [ -s "$STATE_DIR/hosts" ]; then
        echo "$SKILL_DIR/scripts/tunnel_wrap.sh $cf"
      else
        echo "$cf"
      fi ;;
    serveo) echo "/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -R ${SUBDOMAIN}:80:127.0.0.1:${PORT} serveo.net" ;;
    lhr) echo "/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -R 80:127.0.0.1:${PORT} nokey@localhost.run" ;;
    *) die "unknown PHONE_DROP_TUNNEL: $TUNNEL (use cloudflared|serveo|lhr)" ;;
  esac
}

write_units(){
  mkdir -p "$UNITDIR"
  cat >"$UNITDIR/$UNIT_SERVER" <<EOF
[Unit]
Description=phone-drop file server on 127.0.0.1:${PORT}
After=network.target

[Service]
Type=simple
Environment=PHONE_DROP_PORT=${PORT}
Environment=PHONE_DROP_STATE_DIR=${STATE_DIR}
ExecStart=${NODE} ${SKILL_DIR}/scripts/serve.js
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  cat >"$UNITDIR/$UNIT_TUNNEL" <<EOF
[Unit]
Description=phone-drop public tunnel (${TUNNEL})
After=network.target ${UNIT_SERVER}

[Service]
Type=simple
ExecStart=$(tunnel_exec)
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
}

# Only look at journal lines written SINCE the current tunnel start, otherwise a
# previous run's URL is returned and the link is dead.
origin(){
  local st args pat
  case "$TUNNEL" in
    serveo) echo "https://${SUBDOMAIN}.serveousercontent.com"; return 0 ;;
  esac
  st=$(unit_started)
  args=(-n 400 --no-pager)
  [ -n "$st" ] && args=(--since "$st" --no-pager)
  case "$TUNNEL" in
    cloudflared) pat='https://[a-z0-9-]+\.trycloudflare\.com' ;;
    lhr) pat='https://[a-z0-9]+\.lhr\.life' ;;
    *) return 0 ;;
  esac
  journalctl --user -u "$UNIT_TUNNEL" "${args[@]}" 2>/dev/null | grep -oE "$pat" | tail -1 || true
}

cmd_start(){
  [ "$#" -ge 1 ] || die "usage: drop.sh start <file-or-dir> [...]"
  mkdir -p "$STATE_DIR"
  local info u
  info=$("$NODE" "$SKILL_DIR/scripts/make_manifest.js" "$@")
  if [ "$TUNNEL" = cloudflared ] && [ "$HOSTS_FIX" = "1" ]; then update_cf_hosts; fi
  write_units
  systemctl --user stop "$UNIT_TUNNEL" "$UNIT_SERVER" >/dev/null 2>&1 || true
  systemctl --user start "$UNIT_SERVER" "$UNIT_TUNNEL"
  echo "# staged: $info" >&2
  u=$(origin)
  if [ -n "$u" ]; then echo "$u/$(token)/"; else echo "# URL not ready yet - run: drop.sh url" >&2; fi
}

cmd_url(){
  local u; u=$(origin)
  [ -n "$u" ] || die "tunnel URL not available yet (cloudflared takes ~5-10s); retry"
  echo "$u/$(token)/"
}

cmd_verify(){
  local lc pc u host rargs st
  u=$(origin); pc="000"; rargs=()
  lc=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || true); lc=${lc:-000}
  if [ -n "$u" ]; then
    host=$(printf '%s' "$u" | sed -E 's#https://([^/]+).*#\1#')
    # the host resolver can negative-cache a brand-new tunnel name; fall back to a
    # Cloudflare edge IP for the check only (never handed to the user)
    if ! getent hosts "$host" >/dev/null 2>&1; then
      rargs=(--resolve "${host}:443:${PHONE_DROP_VERIFY_IP:-104.16.231.132}")
    fi
    pc=$(curl -s "${rargs[@]}" -o /dev/null -m 20 -w '%{http_code}' "${u}/$(token)/" 2>/dev/null || true); pc=${pc:-000}
  fi
  echo "local=$lc public=$pc"
  [ -n "$u" ] && echo "url=${u}/$(token)/"
  [ "$lc" = 200 ] && [ "$pc" = 200 ] && return 0
  echo "phone-drop: not ready yet (retry 'verify' in a few seconds)" >&2
  if [ "$TUNNEL" = cloudflared ]; then
    st=$(unit_started)
    if ! journalctl --user -u "$UNIT_TUNNEL" --since "$st" -n 400 --no-pager 2>/dev/null | grep -q 'Registered tunnel connection'; then
      echo "phone-drop: the tunnel has NOT connected to the Cloudflare edge yet." >&2
      echo "  - QUIC blocked on this network? this run already uses --protocol $CF_PROTO." >&2
      echo "  - DNS giving 198.18.x fake IPs? retry with PHONE_DROP_CF_HOSTS_FIX=1 (references/troubleshooting.md)" >&2
    fi
  fi
}

cmd_status(){
  systemctl --user --no-pager --lines=0 status "$UNIT_SERVER" "$UNIT_TUNNEL" 2>&1 | sed -n '1,30p' || true
  echo "--- manifest:"; cat "$STATE_DIR/manifest.json" 2>/dev/null || echo "(none)"
}

cmd_stop(){
  systemctl --user disable --now "$UNIT_TUNNEL" "$UNIT_SERVER" >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/manifest.json" "$STATE_DIR/token"
  echo "phone-drop: stopped and cleared manifest"
}

case "${1:-}" in
  start) shift; cmd_start "$@";;
  url) cmd_url;;
  verify) cmd_verify;;
  status) cmd_status;;
  stop) cmd_stop;;
  *) die "usage: drop.sh {start <paths...>|url|verify|status|stop}";;
esac
