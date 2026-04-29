# zigbee

A Swarm Bee client written in pure Zig. Standalone (no FFI to other libp2p
stacks), interoperable with the existing Go bee on the live network.

**Headline focus: IoT / embedded.** zigbee is the small-footprint Bee
client for devices that can't run Go bee — Pi-class boards, edge
gateways, and (planned) microcontrollers. Servers and browsers are
valid targets but not the headline. Roadmap and per-milestone
breakdown:
[`docs/iot-roadmap.html`](docs/iot-roadmap.html). Background and
options analysis: [`docs/strategy.html`](docs/strategy.html).

Source: https://github.com/martinconic/zigbee

Requirements: Zig 0.15.x and a C toolchain (for the vendored libsecp256k1).

## TL;DR — retrieve a file by its Swarm reference

Four commands. Point zigbee at *any* reachable bee (a public bootnode
works) and you can fetch chunks and files by reference, with no peer
addresses to manage:

```bash
# 0. Get the source.
git clone https://github.com/martinconic/zigbee.git
cd zigbee

# 1. Build once.
zig build

# 2. Start the daemon. It dials the --peer node, learns other peers from
#    bee's hive, auto-dials up to 4 of them, and serves an HTTP API on
#    127.0.0.1:9090.
./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10 daemon &
sleep 20      # let the dialer fan out

# 3. Retrieve a file by reference. Zigbee picks the XOR-closest connected
#    peer for that reference and lets bee's forwarding-Kademlia fetch
#    the chunks through the network. No peer address needed.
curl -o myfile.bin "http://127.0.0.1:9090/bzz/<64-char-hex-reference>"
```

That's the whole user-facing flow. Sanity checks and more variants in
[`USAGE.md`](USAGE.md). The architecture (why no peer address is needed,
how forwarding-Kademlia does the heavy lifting on bee's side) is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

> **Both upload styles work.** Bee has two upload endpoints —
> `POST /bytes` (raw, returns a CAC reference) and `POST /bzz` (the
> default for named uploads, wraps the file in a mantaray manifest).
> Zigbee's `/bzz/<ref>` handles **both transparently**: it detects
> the mantaray header on the root chunk and walks the manifest
> (resolving `website-index-document` metadata), or falls through
> to the chunk-tree joiner for raw refs. Verified byte-identical
> against bee's `GET /bzz/<ref>/`.

---

**Current: 0.4.2 — operational polish on top of 0.4's bee-compatible
read-only API.** zigbee connects to the live Swarm network through a
single bootnode, learns other peers via hive, auto-dials up to N of
them, holds those connections open, and serves a **bee-compatible
HTTP API** that existing bee tools / dashboards / curl scripts can
point at without modification: `/health`, `/readiness`, `/node`,
`/addresses`, `/peers`, `/topology`, `/chunks/<addr>`, `/bytes/<ref>`,
`/bzz/<ref>`, `/bzz/<ref>/<path>` and (new in 0.4.2)
`POST /pingpong/<peer-overlay>` — all byte-identical to bee on the
same node, modulo on-chain endpoints we can't yet serve. The daemon
now also exits cleanly on SIGINT/SIGTERM (closes connections with a
clean FIN; bee no longer logs "broadcast failed"). Release notes:
[`RELEASE_NOTES_0.3.md`](RELEASE_NOTES_0.3.md) (forwarding-Kademlia
retrieval + manifest walking),
[`RELEASE_NOTES_0.4.md`](RELEASE_NOTES_0.4.md) (bee-compatible API),
[`RELEASE_NOTES_0.4.1.md`](RELEASE_NOTES_0.4.1.md) (persistent
identity + dead-conn pruning + SOC validation), and
[`RELEASE_NOTES_0.4.2.md`](RELEASE_NOTES_0.4.2.md) (handshake-print
cleanup + `/pingpong` + graceful shutdown).

**Zigbee never needs to know which peer stores a given chunk.** For
every `/retrieve/<hex>` or `/bzz/<reference>` request, it sorts its
connected peers by XOR distance (proximity order) between the chunk
address and each peer's overlay address, and asks the **closest** one.
That bee's own forwarding-Kademlia code then recursively asks *its*
closest peer toward the chunk, and so on, until a bee whose reserve
contains the chunk returns it; the chunk *backwards* hop-by-hop along
the same path. (Book of Swarm §2.3.1, Figure 2.6 — "request
forwarding" / "response backwarding".) Spec §1.5 gives the origin one
extra layer of robustness: if the chosen peer's chain returns
`Delivery{Err}` or the stream resets or our 30 s per-attempt timeout
fires, zigbee re-issues the request through the **next-closest**
connected peer, which produces a different forwarding chain. Result:
a chunk uploaded by any bee on the network is retrievable through any
reachable peer, as long as some live forwarding path between any of
our connected peers and the chunk's neighborhood exists.

You do **not** need to run your own bee — see
[Daemon mode against a public bootnode](#daemon-mode-against-a-public-bootnode).

For the multi-month roadmap (push, full hive routing, on-chain integration,
SOC validation, full-node mode, etc.) see [`PLAN.md`](PLAN.md).
For the current operational status / open issues see [`STATUS.md`](STATUS.md).

---

## What works in 0.4

zigbee speaks the entire boundary protocol stack you need to talk to bee
and reassembles multi-chunk files end-to-end:

| Layer | Module | Status |
|---|---|---|
| TCP transport | `std.net` | ✓ |
| `/multistream/1.0.0` | `src/multistream.zig` | ✓ client + server |
| Noise XX (`/noise`) | `src/noise.zig` | ✓ initiator + responder, KAT-validated |
| Yamux v0 (`/yamux/1.0.0`) | `src/yamux.zig` | ✓ per-stream state, accept/open, flow control basics |
| libp2p Identify (`/ipfs/id/1.0.0`) | `src/identify.zig` | ✓ both sides |
| libp2p Ping (`/ipfs/ping/1.0.0`) | `src/ping.zig` | ✓ responder |
| Bee handshake (`/swarm/handshake/14.0.0`) | `src/bee_handshake.zig` | ✓ both sides — bee accepts us as a connected peer |
| Pricing (`/swarm/pricing/1.0.0`) | `src/pricing.zig` | ✓ both directions |
| Hive peer-discovery (`/swarm/hive/1.1.0`) | `src/hive.zig` | ✓ responder; populates peer table |
| Retrieval (`/swarm/retrieval/1.4.0`) | `src/retrieval.zig` | ✓ initiator; CAC-validated, SOC pass-through |
| `/dnsaddr` resolution | `src/dnsaddr.zig` | ✓ DNS-over-UDP TXT, recursive |
| Daemon + multi-peer connection management | `src/connection.zig`, `src/p2p.zig` | ✓ retry-with-backoff, manage tick, XOR-closest peer for retrieval |
| Multi-peer retrieval iteration (spec §1.5) | `src/p2p.zig` | ✓ tries each connected peer in XOR-asc order, falls through `Err`/reset/30 s timeout to next |
| Per-attempt 30 s watchdog (matches bee `RetrieveChunkTimeout`) | `src/p2p.zig` + `src/yamux.zig` | ✓ Condition.timedWait + `Stream.cancel()` (RST + signal) |
| Chunk-tree (joiner) — multi-chunk file reassembly | `src/joiner.zig` | ✓ branching=128 walk, leaf if `span ≤ payload.len`, SOC-fed-as-CAC detection |
| HTTP API (zigbee-native) | `src/p2p.zig` | ✓ `GET /retrieve/<hex>` (single chunk, payload-only, X-Chunk-Span header) |
| HTTP API (bee-compatible read-only) | `src/p2p.zig` | ✓ `/health`, `/readiness`, `/node` (`beeMode: ultra-light`), `/addresses`, `/peers`, `/topology`, `/chunks/<addr>`, `/bytes/<ref>`, `/bzz/<ref>`, `/bzz/<ref>/<path>`, `POST /pingpong/<peer-overlay>` — drop-in replacement for bee's read-only REST surface, byte-identical responses |
| libp2p Ping initiator (`/ipfs/ping/1.0.0`) | `src/ping.zig` | ✓ used by `POST /pingpong/<peer>` (added 0.4.2) |
| SOC validation (Single-Owner Chunks) | `src/soc.zig` | ✓ added 0.4.1; CAC then SOC in retrieval, returns `ChunkAddressMismatch` if neither validates |
| Persistent libp2p identity + bzz nonce | `src/identity.zig` | ✓ added 0.4.1; 64-byte file at `~/.zigbee/identity.key` (atomic write) |
| Graceful shutdown (SIGINT/SIGTERM) | `src/p2p.zig` | ✓ added 0.4.2; clean FIN on bee side |

Plus the underlying primitives: secp256k1 (vendored libsecp256k1), Ethereum
keccak/eip-191/recoverable-sig, BMT chunk addressing, libp2p PeerID multihash,
multiaddr text/binary parser, hand-rolled protobuf.

**74 unit tests pass** (`zig build test`), including vector tests against
the official Noise XX KAT, bee golden vectors for chunk hashing/overlay
derivation, the bee `pkg/soc/soc_test.go` SOC vector, end-to-end joiner
round-trips for single-leaf and multi-leaf chunk-trees, mantaray header-
detection, and Go-style duration-string golden samples.

## What zigbee is — ultra-light client

Zigbee is an ultra-light Swarm client (lighter than bee's `light: true`
mode):

- ✅ Speaks the full libp2p+Swarm stack against bee.
- ✅ Discovers peers via `/swarm/hive/1.1.0/peers`.
- ✅ Maintains multiple direct peer connections.
- ✅ Retrieves single chunks and reassembles multi-chunk files.
- ❌ No local store — we never store a chunk.
- ❌ No retrieval *responder* — we won't serve chunks to others.
- ❌ No push, no postage stamps, no on-chain integration.

In bee's terms we're closer to *no-storer client* than *light node*. We
never decide which bee in the network has the data, never route a chunk
through ourselves, never do a Kademlia lookup. Bee's swarm of peers
does the forwarding-Kademlia walk on our behalf; we're the requester
at one end and the file-reassembler.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for diagrams and the threading
model.

## What 0.4.x does NOT do

For the cases below the answer is "0.5+ milestone work" — see
[`PLAN.md`](PLAN.md) and [`docs/iot-roadmap.html`](docs/iot-roadmap.html).
The current scope is read-only retrieval; everything below is
acknowledged but deferred.

- ~~**SWAP / off-chain BZZ payment.**~~ — protocol-level work landed
  in 0.5c on `main` (not yet tagged final). zigbee signs EIP-712
  cheques byte-identical to bee's golden vector and emits them on
  `/swarm/swap/1.0.0/swap` after every ~20 retrievals from a peer.
  Issue-only — cashing received cheques on-chain is deferred to 1.0.
  CLI: `--chequebook PATH` to a JSON credential
  `{"contract":"0x..","owner_private_key":"0x..","chain_id":<n>}`.
  Without the flag, accounting still tracks per-peer debt (a one-line
  toggle to enable issuance later). Live verification against a real
  deployed chequebook is **0.5c-e** (the v0.5.0-rc2 milestone).
- **No push.** Cannot upload chunks (`/swarm/pushsync/1.3.1`). Requires
  postage stamps + chain integration. Planned in 0.6.0.
- ~~**No encrypted-chunk references**~~ — landed in 0.5b on `main`
  (not yet tagged). 128-char hex refs (32-byte addr ‖ 32-byte
  symmetric key) traverse the encrypted chunk-tree (branching=64)
  with per-ref keccak256-CTR decryption; works for both
  `/bytes/<128-hex>` and `/bzz/<128-hex>/...`.
- ~~**No local chunk store.**~~ — landed in 0.5a on `main` (not yet
  tagged). Flat-file LRU at `~/.zigbee/store/`, default 100 MiB,
  configurable via `--store-path` / `--store-max-bytes` /
  `--no-store`.

## Build

Prerequisites: a Zig 0.15.x compiler and a working C toolchain (we vendor
and link `libsecp256k1`).

```bash
cd zigbee
zig build           # development default: Debug
zig build test      # 104/104
```

### Release modes

Zig exposes its standard optimisation modes via `-Doptimize=…`. All four
build the same `zig-out/bin/zigbee` and pass the full test suite. Pick
the one that matches how you're using zigbee:

| Mode | Binary | When to pick it |
|---|---|---|
| `Debug` (default) | ~23 MB | Development. Full debug symbols, all safety checks, no optimisation. Compiles fast, runs slowly. |
| `ReleaseSafe` | ~6 MB | **Recommended for production daemons.** -O3 with Zig's safety checks left on (bounds, integer overflow, null-deref). Hostile inputs crash loudly instead of silently corrupting state. |
| `ReleaseFast` | ~5.5 MB | Speed-first. -O3, **safety checks off**. Slightly faster than ReleaseSafe at the cost of giving up the safety net — appropriate when zigbee is the sole consumer of trusted data, or in benchmarks. |
| `ReleaseSmall` | **~1.4 MB** | Size-first. -Os, safety checks off, aggressive dead-code elimination. The right choice for embedded targets, low-bandwidth distribution, or any "every MB matters" deployment. (Future: in-browser via wasm32-freestanding will likely use this.) |

```bash
zig build -Doptimize=ReleaseSafe    # ~6 MB, safety checks on  ← recommended
zig build -Doptimize=ReleaseFast    # ~5.5 MB, safety off, speed-first
zig build -Doptimize=ReleaseSmall   # ~1.4 MB, safety off, size-first
```

Beyond `-Doptimize`, the binary is statically linked against
`libsecp256k1` (vendored under `vendor/secp256k1/`) and dynamically
linked only against libc. Release-mode binaries are already stripped —
running `strip` on them saves nothing further.

You can point the build at a different libsecp256k1 install if you
have one — see `build.zig` for include and library paths.

## Usage

```
zigbee [--peer ip:port] [--network-id N] [SUBCOMMAND ...]

global flags:
  --peer ip:port      peer to dial (default 127.0.0.1:1634)
  --network-id N      Swarm network id (default 10 = Sepolia testnet,
                      mainnet = 1)

subcommands:
  (none)              dial the peer, do the handshake, stay connected
  resolve <host>      /dnsaddr lookup, then exit
  retrieve <hex> [-o file]
                      retrieve one chunk by content address, then exit
  daemon [--max-peers N] [--api-port P]
                      dial --peer as a bootnode, auto-connect to up to
                      N peers via hive (default 4), and serve an HTTP
                      API on 127.0.0.1:P (default 9090):
                        GET /retrieve/<hex>  — fetch one chunk (raw)
                        GET /bzz/<ref>       — fetch a whole file via
                                              chunk-tree traversal
                        GET /peers           — connected-peer JSON
```

### 1. `zigbee` — dial a peer and stay connected

Connects to the peer (defaults to `127.0.0.1:1634`), runs the full
upstream stack, and stays in the accept loop processing inbound streams
from bee. Useful for development: you can hit bee's HTTP API
(`http://127.0.0.1:1633/peers`) in another terminal and confirm zigbee
shows up as a connected peer.

```bash
$ /tmp/bee start --config /path/to/testnet.yaml > /tmp/bee.log 2>&1 &
$ # wait ~15-20 s for bee to be listening on :1634

$ ./zig-out/bin/zigbee
Initializing ZigBee Node...
Generating Node Identity...
Node Overlay Address: 7d54a89be3...
Dialing 127.0.0.1:1634...
Negotiated /noise over TCP.
Sent Initiator Ephemeral Key (`e`).
Received message 2 from Responder. Length: 282 bytes
Successfully decrypted Responder's NoiseHandshakePayload!
Responder signature VALID (key_type=3).
Sent message 3 (`s`, `se`). Noise Handshake Complete!
Noise transport phase initialized; muxer = /yamux/1.0.0 (negotiated via NoiseExtensions).
[host] stream 2: serving /ipfs/id/1.0.0
[identify-out] peer agent: bee/-dev go1.26.0 linux/amd64
[identify-out] peer protocols (15): /ipfs/id/1.0.0, /ipfs/ping/1.0.0, /swarm/handshake/14.0.0/handshake, ...
[bee-hs-out] handshake done: peer overlay=7179856e... full_node=true
[bee-hs-out] welcome: "your welcome meessage"
[host] stream 4: serving /swarm/pricing/1.0.0/pricing
[pricing] peer payment threshold: 3 bytes
[host] stream 6: serving /swarm/hive/1.1.0/peers
[hive] broadcast: 8 added, 0 rejected, table size 8
[hive] non-empty bins: 4/32 — [0]=2 [1]=4 [2]=1 [3]=1
```

In another terminal:
```bash
$ curl -s http://127.0.0.1:1633/peers | jq '.peers | length'
18                                              # was 17, +1 = us
```

zigbee will keep running until you Ctrl-C.

### 2. `zigbee resolve <hostname>` — bootstrap address discovery

Looks up `_dnsaddr.<hostname>` TXT records and recursively resolves the
testnet's `/dnsaddr/...` chain into raw multiaddrs. Equivalent to what
bee does to bootstrap, but as a standalone one-shot.

```bash
$ ./zig-out/bin/zigbee resolve sepolia.testnet.ethswarm.org
resolved 4 multiaddrs for sepolia.testnet.ethswarm.org:
  /ip4/49.12.172.37/tcp/32550/tls/sni/.../ws/p2p/QmZsYC...
  /ip4/49.12.172.37/tcp/32490/p2p/QmZsYC...
  /ip4/167.235.96.31/tcp/32491/p2p/QmediEr...
  /ip4/167.235.96.31/tcp/32551/tls/sni/.../ws/p2p/QmediEr...
```

Pass any of these IPs+ports to `--peer` to dial a real testnet
node — see the [next workflow](#connecting-to-the-live-network-without-a-local-bee).
zigbee can't yet dial the `/ws/` (WebSocket+TLS) variants; only
raw-TCP entries.

### 3. `zigbee daemon` — connect to the network and serve an HTTP API

Dials `--peer` as a bootnode, runs the full handshake, then drives a
hive-fed auto-dialer that opens additional connections (default 4) to
peers learned from the bootnode's broadcasts. Holds those connections
open and exposes them through a tiny HTTP API on `127.0.0.1:9090`.

```
zigbee --peer <bootnode-ip>:<port> --network-id <N> \
       daemon [--max-peers N] [--api-port P]
```

The dialer:
1. Handshakes against `--peer` (the bootnode).
2. Receives hive broadcasts; each announces a batch of known peers.
3. Walks each peer's underlay list (`0x99`-prefixed multi-multiaddr),
   skips private CIDRs / WS-only entries, picks the first public
   IPv4+TCP, and dials it.
4. Tracks per-peer attempts. Failed dials retry with backoff
   (15s / 30s / 60s / 120s, up to 5 attempts).
5. Every 15s, runs a manage tick that re-queues all unconnected
   peers in the table. So as long as hive keeps populating the
   table, a transient network blip won't permanently strand any
   candidate.

Once the daemon is up:

```bash
$ zigbee --peer 167.235.96.31:32491 --network-id 10 \
         daemon --max-peers 4 --api-port 9090 &

# A moment later (give it ~10–30 s for hive broadcasts to arrive):
$ curl -s http://127.0.0.1:9090/peers | jq
{
  "connected": [
    {"overlay": "3ef22bdd…", "ip": "167.235.96.31",  "port": 32491, "full_node": true},
    {"overlay": "097b3be6…", "ip": "49.12.172.37",   "port": 32004, "full_node": true},
    {"overlay": "7eaa24fa…", "ip": "135.181.224.225","port": 32060, "full_node": true},
    {"overlay": "083aae20…", "ip": "135.181.224.224","port": 32044, "full_node": true}
  ],
  "known": 15
}

# Retrieve a chunk; daemon picks the XOR-closest connected peer.
$ curl -s -o chunk.bin -w "%{http_code} %{size_download}\n" \
       "http://127.0.0.1:9090/retrieve/<64-char-hex>"
200 2656

# Or pipe straight to disk:
$ curl -s -o file.bin "http://127.0.0.1:9090/retrieve/<reference>"
```

`/retrieve/<hex>` returns a *single chunk* — useful when you already
know `<hex>` is a leaf chunk address, or for diagnostics. The
response body is the raw chunk payload (no span prefix); the span is
exposed in the `X-Chunk-Span` header. Each request iterates connected
peers in XOR-asc order on `Err` / stream-reset / 30 s timeout, matching
spec §1.5 and bee's `RetrieveChunkTimeout = 30s`.

`/bzz/<reference>` returns the *full file* the reference points to.
zigbee fetches the root chunk, walks the chunk-tree (intermediate
chunks contain concatenated 32-byte child addresses, branching factor
128), and concatenates leaf payloads in order. Each child fetch reuses
the same per-peer iteration as `/retrieve`. Works for any file size:
≤4 KB files are a single-chunk tree (one fetch); larger files traverse
intermediate chunks recursively.

**Only works on CAC-rooted files.** A reference returned by bee's
`POST /bytes` upload is a CAC root (`span ‖ payload` chunk layout). A
reference to a feed index, a manifest entry, or any other Single-Owner
Chunk has a different layout (`id ‖ signature ‖ span ‖ payload`) and
can't be fed to `/bzz/`. zigbee detects this via a span sanity check
and returns `502 LikelySocReference` rather than crashing. Manifest
walking (so `/bzz/<root>/<path>` works) and SOC validation are
follow-on work.

`502` means the iteration exhausted all connected peers (chunk
unreachable from any of their neighborhoods, or a per-attempt timeout
hit on every peer). `503` means no live connections.

`/peers` returns JSON with the live connection list and the known peer
count from hive.

### 4. `zigbee retrieve <hex-addr> [-o file]` — fetch a chunk by content address

Connects to bee on `127.0.0.1:1634`, completes the full upstream
handshake, and asks bee to serve the chunk at `<hex-addr>` (a 64-char
hex string = 32-byte content address). Bee either returns the chunk
from its local store, or forwards the request to its closest peer.
Validates the bytes against the requested address (CAC) and writes them
to `<file>` (or prints hex to stdout if `-o` is omitted).

```bash
# Get a chunk address bee is known to have. The simplest is to extract
# one from bee's log — bee logs `wrapped_chunk_address` whenever it
# receives a chunk via pullsync:
$ CHUNK=$(grep -oE 'wrapped_chunk_address"="[a-f0-9]{64}' /tmp/bee.log | head -1 | cut -d'"' -f3)
$ echo $CHUNK
27f82a81b11f830204e256fc9af30c2a46e044bfed22c5f2a9952c3fef0e4da3

# Sanity-check: bee's REST API returns the chunk too.
$ curl -s -o /tmp/from-bee-api.bin -w "%{size_download}\n" "http://127.0.0.1:1633/chunks/$CHUNK"
2664

# Now retrieve via zigbee.
$ ./zig-out/bin/zigbee retrieve $CHUNK -o /tmp/from-zigbee.bin
[bee-hs-out] handshake done: peer overlay=... full_node=true
[pricing-out] announced our payment threshold to peer
[retrieve] requesting chunk 27f82a81...
[retrieve] got 2656 bytes (span=..., stamp=0 bytes)
[retrieve] wrote 2656 bytes to /tmp/from-zigbee.bin

# bee's /chunks API gives back `span (8 bytes LE) || data`. zigbee's
# output is just `data` (we strip the span). They should match
# byte-for-byte after the 8-byte offset.
$ cmp <(tail -c +9 /tmp/from-bee-api.bin) /tmp/from-zigbee.bin && echo IDENTICAL
IDENTICAL
```

If you ask for an address bee can't find anywhere, you'll see one of:
- `[retrieval] peer reported error: "..."`  — bee returned `Delivery{Err: …}` with a description
- `[retrieve] failed: error.StreamReset`  — bee gave up and reset the stream

Optional: `-o` writes the chunk payload (without the leading 8-byte span)
to the named file. Without `-o`, the bytes are printed to stdout as a
single hex string.

## Workflows

### Workflow: retrieve a file pushed by another bee

This is the canonical "Swarm" use case — someone uploaded a file via
their bee and gave you a reference; you want to read that file.

In 0.1, **this works only for files small enough to fit in a single
chunk** (≤ 4096 bytes). Larger files are stored as a **chunk tree** —
the reference points at a root chunk that lists the addresses of child
chunks; tree traversal is Phase 5 work.

**Small file (≤ 4 KB):**

```bash
# On the bee that has the file (bee with stamps):
$ curl -s -X POST -H "Swarm-Postage-Batch-Id: <batch-id>" \
       --data-binary "@small_file.bin" \
       "http://other-bee:1633/bytes"
{"reference":"<64-char-hex>"}
# The "reference" IS the chunk's content address.

# On the machine running zigbee. Either:
#   (a) dial the same bee (`--peer their-bee:1634`), OR
#   (b) dial a local bee that's connected to the network, OR
#   (c) dial a testnet bootnode and hope the chunk is reachable from
#       its neighborhood (often unreliable — see the bootnode caveat
#       above).
$ ./zig-out/bin/zigbee --peer <peer-ip>:1634 --network-id 10 \
       retrieve <reference> -o small_file_back.bin
$ cmp small_file_back.bin small_file.bin && echo OK
```

The reference IS the address of the single chunk. zigbee fetches it
either directly (if the chosen peer has it locally) or via that
peer's retrieval forwarding.

**Large file (> 4 KB):**

The reference is the address of a `bytes-format` root chunk whose
payload is a list of `(span, child-address)` entries pointing at lower
chunks (or further intermediate chunks for files > a few MB). 0.1
retrieves only the root chunk — you'd see something like 4 KB of
addresses, not the file content. To get the actual file you currently
need to:

1. Fetch the root with `zigbee retrieve <root-ref>`
2. Parse it as a chunk-tree node (parse `span_le_u64 || (entry…)*` where
   each entry is `(span_le_u64, address[32])`)
3. Recursively fetch each child until you reach leaf chunks
4. Concatenate the leaf payloads in order

**This is exactly what Phase 5 will automate.** Until then, 0.1 only
handles the leaf-chunk case directly. If you need the file end-to-end
right now, use `bee`'s `/bzz/<reference>` REST endpoint, which does the
tree traversal for you.

### Workflow: confirm zigbee is recognised as a peer

Useful as a smoke test that everything from Noise through hive is
working.

```bash
# Terminal 1 — start bee:
$ /tmp/bee start --config testnet.yaml > /tmp/bee.log 2>&1 &

# Terminal 2 — wait for bee, run zigbee, leave it up:
$ until ss -tln | grep -q ':1634'; do sleep 1; done
$ ./zig-out/bin/zigbee &
$ ZPID=$!
$ sleep 35   # wait for the full handshake + first hive broadcast

# Terminal 3 — bee should now have us in its peer table.
$ OURS=$(grep -m1 'Node Overlay' /proc/$ZPID/fd/2 || true)
$ curl -s http://127.0.0.1:1633/peers | jq '.peers | length'
18

# Stop:
$ kill $ZPID; pkill -f "/tmp/bee start"
```

bee's log will contain:
```
"msg"="handshake finished for peer (inbound)" "peer_address"="<our overlay>"
"msg"="greeting message from peer" "message"="zigbee says hello"
"msg"="stream handler: successfully connected to peer (inbound)" "light"=" (light)"
```

### Daemon mode against a public bootnode

This is the "no local bee, run as a long-lived process, retrieve via
HTTP API" workflow. Closest analogue to running `bee` itself.

```bash
# Step 1: discover an entry point.
$ ./zig-out/bin/zigbee resolve sepolia.testnet.ethswarm.org
resolved 4 multiaddrs for sepolia.testnet.ethswarm.org:
  /ip4/167.235.96.31/tcp/32491/p2p/QmediEr…    ← raw TCP, usable
  /ip4/49.12.172.37/tcp/32490/p2p/QmZsYC…       ← raw TCP, usable

# Step 2: launch the daemon.
$ ./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10 \
                      daemon --max-peers 4 --api-port 9090 &

# Step 3: wait for the dialer to fan out (10-30s) and check.
$ curl -s http://127.0.0.1:9090/peers | jq '.connected | length'
4

# Step 4: retrieve.
$ curl -s -o chunk.bin "http://127.0.0.1:9090/retrieve/$REFERENCE"
```

**The daemon retrieves through forwarding Kademlia.** Even if your
chunk isn't stored by any of your 4 connected peers, each of those
peers will forward the request to the closest peer it knows toward the
chunk's neighborhood — and recursively from there. Any chunk uploaded
to the network by another bee is reachable, given a live path. Tested
on testnet against `167.235.96.31:32491`:

```
$ curl -sw "%{http_code} %{size_download}b\n" -o chunk.bin \
       "http://127.0.0.1:9090/retrieve/27f82a81b11f830204e256fc9af30c2a46e044bfed22c5f2a9952c3fef0e4da3"
200 2656b
```

If the chunk genuinely doesn't exist, the daemon's log shows it
iterating through every connected peer:
```
[api] /retrieve …: trying 4 peers in XOR-asc order
[api] /retrieve attempt 1/4 → peer 6430eaa8…
[api] /retrieve attempt 1 failed against 6430eaa8…: error.PeerError
…
[api] /retrieve attempt 4/4 → peer 3711bbf3…
[api] /retrieve attempt 4 failed against 3711bbf3…: error.PeerError
```
…then returns 502 with `exhausted N connected peers; last error: …`.

For mainnet, replace `sepolia.testnet.ethswarm.org` with
`mainnet.ethswarm.org` and `--network-id 10` with `--network-id 1`.

### Connecting to the live network without a local bee (one-shot)

You don't need a local bee node. Pass `--peer ip:port` to dial any
TCP-reachable bee — a friend's node, a private gateway, or a public
testnet bootnode.

**Step 1 — find an entry point** with `zigbee resolve`:

```bash
$ ./zig-out/bin/zigbee resolve sepolia.testnet.ethswarm.org
resolved 4 multiaddrs for sepolia.testnet.ethswarm.org:
  /ip4/167.235.96.31/tcp/32491/p2p/QmediEr…    ← raw TCP, usable
  /ip4/167.235.96.31/tcp/32551/tls/sni/…/ws/…   ← TLS+WS, NOT usable in 0.1
  /ip4/49.12.172.37/tcp/32490/p2p/QmZsYC…       ← raw TCP, usable
  /ip4/49.12.172.37/tcp/32550/tls/sni/…/ws/…    ← TLS+WS, NOT usable
```

For mainnet: `zigbee resolve mainnet.ethswarm.org` and use
`--network-id 1`.

**Step 2 — connect.** zigbee handshakes against any of the raw-TCP
entries:

```bash
$ ./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10
…
[bee-hs-out] handshake done: peer overlay=3ef22bdd… network=10 full_node=true
[bee-hs-out] welcome: "Welcome to the Testnet!"
[host] stream 4: serving /swarm/pricing/1.0.0/pricing
[host] stream 6: serving /swarm/hive/1.1.0/peers
[hive] broadcast: 7 added, 0 rejected, table size 7
```

The bootnode accepts us, sends its welcome message, and broadcasts a
batch of 7 testnet peers via hive — all from a public-internet
connection, no local bee involved.

**Step 3 — retrieve a chunk.** The protocol works against any peer
that has the chunk reachable in its neighborhood:

```bash
$ ./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10 \
    retrieve 45e446e17722e22cca976d283e80e8c5d99acf0e412cc7c39ff49be84d3b2b3d \
    -o ./chunk.bin
```

#### Note: prefer `daemon` mode for network retrieval

A single one-shot `retrieve` against a bootnode goes through *one*
peer and gives up if that peer's forward chain returns `Err`. The
spec's intended retry-the-next-peer loop only kicks in when zigbee
is holding multiple connections — which is what `daemon` mode does
(see [Daemon mode against a public bootnode](#daemon-mode-against-a-public-bootnode)).
For most "I want to fetch a chunk from the live network" use cases,
the daemon is the right tool: it iterates connected peers in
XOR-asc order until one of them (via its own forwarding) finds the
chunk.

### Workflow: retrieve a file someone uploaded from another bee

If a friend has bee, uploads a small (≤ 4 KB) file via:

```bash
# On their bee:
$ curl -X POST -H "Swarm-Postage-Batch-Id: <batch>" \
       --data-binary "@hello.txt" \
       http://their-bee:1633/bytes
{"reference":"45e446e17722e22cca976d283e80e8c5d99acf0e412cc7c39ff49be84d3b2b3d"}
```

…you can retrieve it without running your own bee, by dialing their
bee directly:

```bash
$ ./zig-out/bin/zigbee --peer their-bee:1634 --network-id 10 \
    retrieve 45e446e17722e22cca976d283e80e8c5d99acf0e412cc7c39ff49be84d3b2b3d \
    -o hello.txt
```

If the file is larger than 4 KB, the reference points at a chunk-tree
root rather than the data itself; 0.1 retrieves only the root chunk
(see [Workflow: retrieve a file pushed by another bee](#workflow-retrieve-a-file-pushed-by-another-bee)
above for the chunk-tree caveat). Phase 5 will add automatic
tree-traversal for full files.

## Architecture overview

The codebase is flat (everything in `src/`). Modules in dependency
order, bottom up:

| Layer | Files |
|---|---|
| Crypto / hashing | `crypto.zig`, `bmt.zig`, `identity.zig`, `bzz_address.zig` |
| Multiformats | `multiaddr.zig`, `peer_id.zig`, `proto.zig` (varint + protobuf primitives) |
| DNS / resolution | `dnsaddr.zig` |
| libp2p stack | `multistream.zig`, `noise.zig`, `noise_kat.zig`, `libp2p_key.zig`, `yamux.zig`, `identify.zig`, `ping.zig` |
| Bee application | `swarm_proto.zig` (delimited framing + Headers exchange), `bee_handshake.zig`, `pricing.zig`, `hive.zig`, `peer_table.zig`, `retrieval.zig` |
| Top-level | `p2p.zig` (the host: dial, accept, dispatch by protocol), `main.zig` (CLI) |

Concurrency model is OS threads + `std.Thread.Mutex`/`Condition`. The Yamux
session runs a dedicated reader thread; each accepted peer-initiated stream
is handled inline by the dispatcher.

The vendored C dep is `libsecp256k1` (used by `identity.zig` for ECDSA
sign/recover). Everything else is pure Zig (and Zig std for ChaChaPoly,
X25519, Keccak, SHA2, ECDSA-P256 — bee uses ECDSA-P256 for its libp2p
identity).

## Known issues and rough edges

- The `IdentifyInitiatorCtx` heap allocation in `dial()` is not freed.
  Per-process leak; harmless for one-shot CLI but wrong for a daemon.
- We hardcode `network_id = 10` and `127.0.0.1:1634` in `main.zig`.
- `runRetrieval` sleeps 500 ms before opening the retrieval stream to
  give bee's `accounting.Connect` goroutine a chance to run. Real
  product would do this with a proper signal — but 500 ms is enough on
  the testnet today.
- Bee logs `"could not broadcast to peer"` when zigbee disconnects
  (e.g. on retrieve completion). It's bee trying to push a hive update
  to a peer that just left. Cosmetic.
- We send 13_500_000 as our payment threshold to bee — that's bee's
  full-node default. Bee rejects anything below 9_000_000 (= 2 ×
  refreshRate). This means we technically claim a higher threshold than
  a real light node would, but for retrieval-only this is harmless;
  bee's accounting would only catch up if we were issuing many
  retrievals back-to-back.

## Roadmap

See [`PLAN.md`](PLAN.md). Next planned work is Phase 5
(pushsync + SOC validation + chunk-tree traversal so the "retrieve a large
file" workflow lights up). Beyond that: full hive routing, Eth RPC client,
postage stamps, redistribution.

## Tests

```bash
zig build test --summary all
```

Currently: **58 / 58 passing**.

The interesting ones:
- `noise_kat`: Cacophony Noise_XX_25519_ChaChaPoly_SHA256 vector + a
  flynn/noise oracle test (libp2p-config empty-prologue) → both
  byte-match.
- `bmt`: bee golden vectors for chunk addressing — `foo` and
  `greaterthanspan`.
- `identity`: 4 overlay golden vectors from `bee/pkg/crypto/crypto_test.go`.
- `bzz_address`: signed-overlay round-trip + rejection of mismatched
  overlay.
- `peer_table`: closest-peer XOR distance test, self-overlay drop,
  upsert-replaces-not-duplicates.
- `multiaddr`: round-trip of `/ip4/.../tcp/.../p2p/Qm...` text↔binary,
  including base58btc PeerID decoding.
- `dnsaddr`: parser tests; live testnet resolution checked via the
  CLI subcommand.

## License

(TBD — match whatever license the user wants. Bee is BSD-3-Clause; the
vendored libsecp256k1 is MIT.)
