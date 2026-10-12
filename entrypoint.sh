#!/bin/sh
# Entrypoint for running TiredVPN on Fly.io.
#
# Environment variables:
#   TIREDVPN_SECRET   optional shared secret. If unset, one is generated and
#                     printed to the logs (`fly logs`). With a volume mounted at
#                     DATA_DIR it is saved there and stays the same across
#                     restarts; without a volume it changes on every restart.
#   PORT              TCP port to listen on inside the VM (default 443)
#   DATA_DIR          persistent directory (the Fly volume mount, e.g. /data)
#   TIREDVPN_IP_POOL  CIDR for TUN clients, e.g. 10.8.0.0/24. Empty = proxy-only.
#   TIREDVPN_TUN_IP   server-side TUN address (default 10.8.0.1)
#   TLS_CERT_B64      optional base64 PEM certificate (stable cert across restarts)
#   TLS_KEY_B64       optional base64 PEM private key
#   TLS_CN            CN for the generated self-signed cert (default: <FLY_APP_NAME>.fly.dev)
#   TIREDVPN_DEBUG    set to 1 for verbose logging
#   TIREDVPN_EXTRA_ARGS  extra flags appended to the server command
set -eu

CERT_DIR=/app/certs
DATA_DIR="${DATA_DIR:-}"
PERSIST=0
if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] && [ -w "$DATA_DIR" ]; then
  PERSIST=1
  CERT_DIR="$DATA_DIR/certs"
  mkdir -p "$CERT_DIR"
fi

# ---------------------------------------------------------------- secret ----
SECRET_GENERATED=0
if [ -z "${TIREDVPN_SECRET:-}" ]; then
  if [ "$PERSIST" = "1" ] && [ -s "$DATA_DIR/secret" ]; then
    TIREDVPN_SECRET="$(cat "$DATA_DIR/secret")"
    SECRET_GENERATED=1
  else
    TIREDVPN_SECRET="$(openssl rand -hex 32)"
    SECRET_GENERATED=1
    if [ "$PERSIST" = "1" ]; then
      umask 077
      printf '%s' "$TIREDVPN_SECRET" > "$DATA_DIR/secret"
    fi
  fi
fi
export TIREDVPN_SECRET

if [ "$SECRET_GENERATED" = "1" ]; then
  echo "=============================================================="
  echo " TIREDVPN_SECRET (auto-generated):"
  echo " $TIREDVPN_SECRET"
  if [ "$PERSIST" = "1" ]; then
    echo " Saved on the volume; it stays the same across restarts."
  else
    echo " WARNING: no volume mounted at DATA_DIR, so this secret CHANGES on every"
    echo " restart. Create the volume from fly.toml or set it permanently with:"
    echo "   fly secrets set TIREDVPN_SECRET=<value>"
  fi
  echo "=============================================================="
fi

# ------------------------------------------------------------------ cert ----
CERT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"
mkdir -p "$CERT_DIR"

if [ -n "${TLS_CERT_B64:-}" ] && [ -n "${TLS_KEY_B64:-}" ]; then
  echo "Using TLS certificate from TLS_CERT_B64 / TLS_KEY_B64"
  printf '%s' "$TLS_CERT_B64" | base64 -d > "$CERT"
  printf '%s' "$TLS_KEY_B64" | base64 -d > "$KEY"
elif [ "$PERSIST" = "1" ] && [ -s "$CERT" ] && [ -s "$KEY" ]; then
  echo "Reusing TLS certificate from the volume"
else
  CN="${TLS_CN:-}"
  if [ -z "$CN" ]; then
    if [ -n "${FLY_APP_NAME:-}" ]; then CN="${FLY_APP_NAME}.fly.dev"; else CN="localhost"; fi
  fi
  echo "Generating self-signed TLS certificate for CN=$CN"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes -keyout "$KEY" -out "$CERT" \
    -subj "/CN=$CN" >/dev/null 2>&1
fi
chmod 600 "$KEY"

# ------------------------------------------------------------------- tun ----
TUN_ARGS=""
if [ -n "${TIREDVPN_IP_POOL:-}" ]; then
  TUN_DEV="${TUN_DEV:-/dev/net/tun}"
  if [ ! -c "$TUN_DEV" ]; then
    mkdir -p "$(dirname "$TUN_DEV")"
    mknod "$TUN_DEV" c 10 200 2>/dev/null || echo "WARNING: could not create $TUN_DEV; TUN mode may not work"
  fi
  echo "TUN mode enabled, client pool ${TIREDVPN_IP_POOL}"
  TUN_ARGS="-tun-ip ${TIREDVPN_TUN_IP:-10.8.0.1} -ip-pool ${TIREDVPN_IP_POOL}"
else
  echo "TUN mode disabled (TIREDVPN_IP_POOL is empty), proxy-only"
fi

# ----------------------------------------------------------------- start ----
DEBUG_FLAG=""
if [ "${TIREDVPN_DEBUG:-0}" = "1" ]; then
  DEBUG_FLAG="-debug"
fi

if [ -n "${FLY_APP_NAME:-}" ]; then
  echo "Client command:"
  echo "  tiredvpn client -server ${FLY_APP_NAME}.fly.dev:443 -secret <secret above> -tun -tun-routes 0.0.0.0/0"
fi

echo "Starting tiredvpn server on :${PORT:-443}/tcp (QUIC disabled)"

# -secret is read from TIREDVPN_SECRET by the binary itself, so it does not
# appear in the process list.
# shellcheck disable=SC2086
exec /usr/local/bin/tiredvpn server \
  -listen ":${PORT:-443}" \
  -dual-stack=false \
  -no-quic \
  -cert "$CERT" \
  -key "$KEY" \
  -fake-root /app/www \
  $TUN_ARGS \
  $DEBUG_FLAG \
  ${TIREDVPN_EXTRA_ARGS:-}
