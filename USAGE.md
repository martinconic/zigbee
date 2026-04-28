# zigbee — usage walkthroughs

Real, copy-pasteable command sequences. If anything is unclear, the
single-page mental model lives in [`ARCHITECTURE.md`](ARCHITECTURE.md).

For each scenario the steps are: **(1) start zigbee** → **(2) wait for
peers** → **(3) request the file**. None of these needs you to know
which bee in the network has the chunk.

---

## Reference types: raw vs. manifest

Bee has two upload endpoints. **Both produce references that
zigbee's `/bzz/<ref>` handles transparently.**

| Bee endpoint | What gets stored | Zigbee `/bzz/<ref>` behaviour |
|---|---|---|
| `POST /bytes` | Raw file content as a CAC chunk-tree | Detects no manifest header → joiner walks the chunk-tree → returns file bytes. |
| `POST /bzz` (default for files with `name=`) | Mantaray **manifest** wrapping the file | Detects mantaray magic on the root chunk → walks the trie (resolves the `"/"` fork's `website-index-document` metadata) → joiner walks the resulting CAC tree → returns file bytes. Same result as `bee /bzz/<ref>/`. |

Verified: zigbee `/bzz/<manifest-ref>` returns the same 2742 bytes
that `bee /bzz/<manifest-ref>/` does, byte-identical, on the same
local upload.

If you ever want the **raw chunk** (e.g. to inspect a manifest's bytes
or fetch a single intermediate chunk), use `/retrieve/<addr>` instead
of `/bzz/<ref>`. That path skips the joiner and the manifest detector.

---

## 1. Quickstart — fetch a file from the live testnet

You have a Swarm reference (a 64-char hex string) for a file someone
uploaded via `bee /bytes`. You want the bytes back. You don't run a
bee yourself.

```bash
# Build
cd /path/to/zigbee
zig build

# Start the daemon. --peer is the bootstrap entry — any TCP-reachable
# bee will do. This one is the public Sepolia testnet bootnode.
./zig-out/bin/zigbee \
    --peer 167.235.96.31:32491 \
    --network-id 10 \
    daemon \
    --max-peers 4 \
    --api-port 9090 \
    > /tmp/zigbee.log 2>&1 &

# Give the dialer 15-30 s to fan out via hive.
sleep 25

# Sanity-check: how many peers are connected, how many are known via hive?
curl -s http://127.0.0.1:9090/peers | jq
# {
#   "connected": [
#     {"overlay":"3ef22bdd…","ip":"167.235.96.31",...,"full_node":true},
#     {"overlay":"097b3be6…","ip":"49.12.172.37",...,"full_node":true},
#     {"overlay":"7eaa24fa…","ip":"135.181.224.225",...,"full_node":true},
#     {"overlay":"083aae20…","ip":"135.181.224.224",...,"full_node":true}
#   ],
#   "known": 15
# }

# Retrieve a file. NO peer address in this URL — zigbee picks the
# XOR-closest connected peer to the reference and that bee's
# forwarding-Kademlia takes care of finding the storer through the network.
REF=499319673e7f1722c5489246b1556b55e1dafb8aa568c3d17c8b0786b8c14594
curl -s -o ./myfile.bin "http://127.0.0.1:9090/bzz/$REF"

# Stop the daemon when done.
kill %1
```

That's it. Three commands once everything's built (start daemon, sleep,
curl).

> **Realistic caveat for testnet:** the testnet swarm is small and
> chunks aren't always replicated densely. If the closest connected
> peer's forwarding chain can't reach the chunk's storer, zigbee
> automatically tries the next-closest connected peer (spec §1.5
> origin retry). If none of them can reach the chunk, you'll see HTTP
> 502 with a body like `exhausted N connected peers; last error: …`.
> Increase `--max-peers` for a wider candidate pool.

---

## 2. End-to-end loop against a local bee

Use this when you want to *verify* zigbee correctness against bee's own
REST API. Bee uploads a file (it has stamps), zigbee retrieves the same
reference back, you `cmp` the bytes.

```bash
# Step 0: bee binary somewhere; testnet config in ./testnet.yaml.
/tmp/bee start --config ./testnet.yaml > /tmp/bee.log 2>&1 &
until curl -sf http://127.0.0.1:1633/health >/dev/null; do sleep 1; done
echo "bee up"

# Step 1: bee needs a postage stamp to upload. This costs gas; works on
# the testnet because the bee config has a wallet with test BZZ + ETH.
BATCH=$(curl -s -X POST "http://127.0.0.1:1633/stamps/100000000/17" \
        | jq -r .batchID)
echo "stamp batch: $BATCH (will take ~60-120 s to confirm on-chain)"
until curl -sf "http://127.0.0.1:1633/stamps/$BATCH" | jq -e '.usable' >/dev/null; do
  sleep 5
done
echo "stamp usable"

# Step 2: upload a file, capture the reference.
echo "hello swarm $(date)" > /tmp/in.txt
REF=$(curl -s -X POST -H "Swarm-Postage-Batch-Id: $BATCH" \
            --data-binary "@/tmp/in.txt" \
            http://127.0.0.1:1633/bytes \
       | jq -r .reference)
echo "reference: $REF"

# Step 3: start zigbee against the local bee. --max-peers 1 because
# we only need this one bee to answer.
cd /path/to/zigbee
./zig-out/bin/zigbee \
    --peer 127.0.0.1:1634 \
    --network-id 10 \
    daemon --max-peers 1 --api-port 9090 \
    > /tmp/zigbee.log 2>&1 &
sleep 12

# Step 4: retrieve via zigbee, confirm bytes match the original.
curl -s -o /tmp/out.txt "http://127.0.0.1:9090/bzz/$REF"
cmp /tmp/in.txt /tmp/out.txt && echo "BYTE-IDENTICAL"

# Cleanup
kill %2 %1
```

Verified live in this repo's testing: 1500-byte and 10 000-byte files
round-trip byte-identical (the 10 KB case exercises the joiner — root
chunk + 2 leaf children — the same chunk-tree walk that handles larger
files).

> **What about big files?** Past ~25–30 chunks (≈ 100 KB at typical
> proximity pricing) per peer, bee's accounting (`disconnect threshold
> exceeded`) stops serving us until we pay via SWAP cheques. Zigbee
> doesn't yet implement SWAP — that's Phase 6. For now: small files
> work end-to-end; daemon mode with `--max-peers N` extends the budget
> to roughly N × 25–30 chunks before bee-side accounting kicks in.

---

## 3. Single-chunk fetch (raw)

If your reference is the address of *one* chunk (≤ 4096 bytes payload)
and you don't want chunk-tree reassembly, use `/retrieve` instead of
`/bzz`. The wire-level result is identical for single-chunk files, but
`/retrieve` skips the joiner and exposes the chunk's span as a header.

```bash
# (Daemon already running.)
curl -s -D - -o ./chunk.bin \
     "http://127.0.0.1:9090/retrieve/<64-char-hex-address>"
# HTTP/1.1 200 OK
# Content-Type: application/octet-stream
# Content-Length: <chunk-payload-length>
# X-Chunk-Span: <span-as-decimal-uint64>
```

Use this for diagnostics or if you're fetching a single chunk by its
address (e.g. inspecting an intermediate node of someone else's chunk
tree). For "I have a Swarm file reference and I want the file content
back", use `/bzz/<reference>`.

---

## 4. One-shot CLI mode (no daemon, no HTTP)

If you don't need the long-running daemon, the CLI also has a one-shot
retrieve:

```bash
./zig-out/bin/zigbee \
    --peer 167.235.96.31:32491 --network-id 10 \
    retrieve <64-char-hex-address> -o ./chunk.bin
```

This dials, completes the handshake, fetches one chunk, writes it,
exits. No HTTP API; no chunk-tree reassembly (so for files > 4 KB you'd
get just the root chunk, which is the list of child references, not
the file content). For "real" usage prefer daemon mode.

---

## 5. Mainnet

Same as testnet except the bootnode and network-id change. Resolve the
mainnet bootnodes via `/dnsaddr/`:

```bash
./zig-out/bin/zigbee resolve mainnet.ethswarm.org
# resolved <N> multiaddrs for mainnet.ethswarm.org:
#   /ip4/.../tcp/.../p2p/<peer-id>
#   /ip4/.../tcp/.../tls/.../ws/p2p/<peer-id>     ← TLS+WS, NOT yet usable
#   ...
```

Use a `/ip4/.../tcp/...` entry (raw TCP, no `/ws/`) and start the daemon:

```bash
./zig-out/bin/zigbee \
    --peer <ip>:<port> \
    --network-id 1 \
    daemon
```

---

## 6. HTTP API reference

Once the daemon is running on `127.0.0.1:<api-port>` (default 9090),
the surface is **bee-compatible** for read-only operations: existing bee
tools, dashboards, and curl scripts that consume bee's API can point at
zigbee unmodified.

### Bee-compatible endpoints (drop-in for `bee` read-only surface)

| Method | Path | Returns |
|---|---|---|
| `GET` | `/health` | `{"status":"ok","version":"<zigbee-ver>","apiVersion":"<bee-shape>"}` — service liveness probe (bee-shape). |
| `GET` | `/readiness` | Alias of `/health`. |
| `GET` | `/node` | `{"beeMode":"ultra-light","chequebookEnabled":false,"swapEnabled":false}` — bee's enum already has `UltraLightMode`. |
| `GET` | `/addresses` | `{"overlay":"...","underlay":[],"ethereum":"0x...","chain_address":"0x...","publicKey":"...","pssPublicKey":"..."}` — bee-shape identity. |
| `GET` | `/peers` | `{"peers":[{"address":"<overlay-hex>","fullNode":bool},…]}` — bee-shape. |
| `GET` | `/topology` | `{"baseAddr":"...","population":N,"connected":M,"bins":{…}}` — Kademlia bin populations. |
| `GET` | `/chunks/<addr>` | Raw chunk = `span(8 LE) ‖ payload`, `Content-Type: binary/octet-stream`. Same protocol underneath as `/retrieve`, different output shape. |
| `GET` | `/bytes/<reference>` | File via the chunk-tree joiner. **No manifest detection** — matches `bee POST /bytes` ↔ `bee GET /bytes/<ref>` semantics. |
| `GET` | `/bzz/<reference>` | File via joiner, **manifest-aware**: detects mantaray header on the root chunk, walks `website-index-document`, then runs the joiner. Matches `bee GET /bzz/<ref>/`. |
| `GET` | `/bzz/<reference>/<path>` | Manifest path lookup. Walks the mantaray trie matching `<path>` and returns the entry. |

### Zigbee-native (legacy)

| Method | Path | Returns |
|---|---|---|
| `GET` | `/retrieve/<hex>` | Single chunk, payload-only body (no span prefix). The chunk's span is exposed via the `X-Chunk-Span` header. The original 0.1 endpoint, kept for back-compat with existing scripts. |

HTTP status codes:

| Code | Meaning |
|---|---|
| `200` | Success — body is the chunk/file. |
| `400` | Reference isn't a 64-char hex string. |
| `404` | Unknown path. |
| `502` | Iterated all connected peers; none could deliver. Body explains why (`error.PeerError`, `error.StreamReset`, `LikelySocReference`, etc.). |
| `503` | No live peer connections at all. Daemon hasn't fanned out yet, or all peers have disconnected. |

---

## 7. Operational notes

- **First retrieval after daemon start may take a few seconds** while
  the auto-dialer is still fanning out. After ~30 s the connections
  stabilise.
- **Daemon log goes to stdout/stderr.** Pipe to a file for diagnostics:
  the per-attempt log lines (`[retrieve] attempt N/M → peer …`,
  `[retrieve] attempt N failed against …: …`) are the canonical way to
  see whether iteration is firing.
- **`Ctrl-C`** stops the daemon. Connections drop via TCP RST; bee
  logs a "broadcast failed" line. Cosmetic.
- **No persistence yet.** Every restart generates a fresh libp2p
  identity and a fresh overlay; bee tracks debt per-peer, so a
  restart resets the per-peer credit window (handy for testing, not
  what a real client should do).
