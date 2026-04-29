#!/usr/bin/env bash
# 4-retrieve.sh — convenience wrapper: ask zigbee for a Swarm reference,
# write the bytes to a file, time the request, print a summary.
#
# Run this in a SECOND terminal while ./3-run-zigbee.sh is running.
#
# Usage: ./4-retrieve.sh <reference> [output-file]
#
#   <reference>   64-char hex (unencrypted) or 128-char hex (encrypted —
#                 32-byte address ‖ 32-byte symmetric key)
#   <output-file> default: /tmp/zigbee-retrieved.bin
#
# Example:
#   ./4-retrieve.sh 43e7fb75c76a1c88d8d715ed0870dcaff3e6856d333ab7d73b4f14d108b3e838 ./out.bin
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

REF="${1:-}"
OUT="${2:-/tmp/zigbee-retrieved.bin}"

if [ -z "$REF" ]; then
    echo "usage: $0 <reference> [output-file]" >&2
    echo "  <reference> is 64-char hex (unencrypted) or 128-char hex (encrypted)" >&2
    exit 2
fi

# Length sanity (helpful early error)
case ${#REF} in
    64|128) ;;
    *)
        echo "error: reference must be 64 or 128 hex characters; got ${#REF}." >&2
        exit 2 ;;
esac

if ! curl -sf "http://127.0.0.1:$API_PORT/peers" >/dev/null 2>&1; then
    echo "error: zigbee daemon not responding on 127.0.0.1:$API_PORT" >&2
    echo "  start it first: ./3-run-zigbee.sh (in another terminal)" >&2
    exit 1
fi

t0=$(date +%s%N)
HTTP=$(curl -s -o "$OUT" -w "%{http_code}" "http://127.0.0.1:$API_PORT/bytes/$REF")
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))

SIZE=$(wc -c < "$OUT" 2>/dev/null || echo 0)

echo "[4-retrieve] HTTP=$HTTP  elapsed=${elapsed_ms}ms  bytes=$SIZE"
echo "             output: $OUT"

if [ "$HTTP" = "200" ]; then
    echo "[4-retrieve] OK"
    exit 0
fi

echo "[4-retrieve] FAILED — HTTP $HTTP" >&2
case "$HTTP" in
    404)
        echo "  zigbee couldn't find the reference. Check that:"
        echo "    1. the ref is correct;"
        echo "    2. zigbee has connected peers (curl http://127.0.0.1:$API_PORT/peers);"
        echo "    3. some peer in the network actually stores the chunks." ;;
    502)
        echo "  zigbee tried every connected peer and none could serve a chunk."
        echo "  Increase MAX_PEERS in config.sh and restart, or wait for the"
        echo "  hive-fed dialer to populate more peers." ;;
esac
exit 1
