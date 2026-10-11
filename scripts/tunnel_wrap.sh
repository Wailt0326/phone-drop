#!/usr/bin/env bash
# Run a tunnel command with a corrected /etc/hosts.
#
# Why: when a Windows proxy/VPN owns DNS for WSL, *.argotunnel.com resolves to a
# fake IP in 198.18.0.0/15 that WSL cannot route, and cloudflared fails with
# "TLS handshake with edge error: EOF". Binding a hosts file with the real edge IPs
# (written by drop.sh from DoH) works around it. A user+mount namespace is used so
# no root is required.
#
# Enabled with PHONE_DROP_CF_HOSTS_FIX=1.
set -euo pipefail
HOSTS="${PHONE_DROP_HOSTS:-$HOME/.phone-drop/hosts}"
[ -s "$HOSTS" ] || exec "$@"
if command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
  export PHONE_DROP_HOSTS="$HOSTS"
  exec unshare -rm bash -c 'mount --bind "$PHONE_DROP_HOSTS" /etc/hosts 2>/dev/null || true; exec "$@"' bash "$@"
fi
exec "$@"
