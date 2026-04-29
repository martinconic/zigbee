#!/usr/bin/env bash
# 3-run-zigbee.sh — start the zigbee daemon, dialing the configured
# bootnode and loading the chequebook credential. Foreground process —
# Ctrl-C to stop. The HTTP API serves on 127.0.0.1:$API_PORT.
#
# This wraps the equivalent of:
#   zigbee --bootnode "$BOOTNODE" \
#          --network-id "$NETWORK_ID" \
#          --chequebook "$CHEQUEBOOK" \
#          daemon --max-peers "$MAX_PEERS" --api-port "$API_PORT"
#
# Configuration: see config.example.sh.
#
# Usage: ./3-run-zigbee.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ensure_zigbee_built
ensure_identity

if [ ! -r "$CHEQUEBOOK" ]; then
    echo "warning: $CHEQUEBOOK not found — accounting will track but never issue." >&2
    echo "  retrieval will stop at ~25 chunks per peer. Run ./2-deploy-chequebook.sh first." >&2
    CHEQUEBOOK_FLAG=()
else
    CHEQUEBOOK_FLAG=(--chequebook "$CHEQUEBOOK")
fi

cat <<EOF >&2
[3-run-zigbee] starting daemon
    binary       $ZIGBEE_BIN
    bootnode     $BOOTNODE
    network-id   $NETWORK_ID
    chequebook   ${CHEQUEBOOK:-<none>}
    max-peers    $MAX_PEERS
    api-port     $API_PORT

  HTTP API will be available at http://127.0.0.1:$API_PORT
  Try:
    curl http://127.0.0.1:$API_PORT/peers
    curl http://127.0.0.1:$API_PORT/bytes/<64-char-hex-ref> -o file

  Ctrl-C to stop. State persists at \$HOME/.zigbee/.

EOF

exec "$ZIGBEE_BIN" \
    --bootnode "$BOOTNODE" \
    --network-id "$NETWORK_ID" \
    "${CHEQUEBOOK_FLAG[@]}" \
    daemon \
    --max-peers "$MAX_PEERS" \
    --api-port "$API_PORT"
