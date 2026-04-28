# zigbee 0.3 — release notes

**Date:** 2026-04-28
**Goal:** "I have a Swarm reference (any kind) — give me back the file."
**Status:** ✅ achieved end-to-end against bee.

## Headline

```bash
# 1. Build once.
zig build

# 2. Start the daemon. Point it at any reachable bee — a public testnet
#    bootnode works. Zigbee dials it, learns other peers via hive,
#    auto-connects to up to --max-peers of them, serves an HTTP API.
./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10 daemon &

# 3. Retrieve any file by reference. NO peer address needed. Both
#    raw-bytes references (POST /bytes) and manifest references
#    (POST /bzz?name=foo, the bee default) work.
curl -o myfile.bin "http://127.0.0.1:9090/bzz/<reference>"
```

Verified live against a local bee with a real upload:

```
$ REF=d7c5e8fe0a52bb2db47c6410c78ed7e4b86dbf31f5e6bc985afd2c901cf69de7
$ curl -o /tmp/zb.bin  http://127.0.0.1:9091/bzz/$REF       # zigbee
$ curl -o /tmp/bee.bin http://127.0.0.1:1633/bzz/$REF/      # bee (reference)
$ cmp /tmp/zb.bin /tmp/bee.bin && echo IDENTICAL
IDENTICAL                                                    # 2742 bytes
```

## What's new since 0.1

0.1 was *one chunk via the CLI*. 0.3 is *any file via an HTTP API,
through the live network, by reference alone* — the user-facing
experience matches bee.

### Daemon mode (Phase 5a)

- Long-running process. `zigbee --peer X --network-id N daemon
  --max-peers M --api-port P` dials X as a bootstrap, holds the
  connection, and serves on `127.0.0.1:P`.
- Heap-allocated `Connection` (`src/connection.zig`) owns
  TCP + NoiseStream + YamuxSession; `dial()` runs the full
  upstream stack; `startAcceptLoop()` spawns a per-connection
  thread dispatching inbound peer-initiated streams (Identify,
  Ping, hive responder, pricing announce-back).
- HTTP API on 127.0.0.1:9090: `GET /retrieve/<hex>` (single chunk),
  `GET /bzz/<reference>` (full file), `GET /peers` (connection +
  hive-table JSON).

### Multi-peer connection management (Phase 5b)

- Hive-fed auto-dialer: the bootnode's `/swarm/hive/1.1.0/peers`
  broadcasts populate a candidate queue; the dialer drains them up
  to `--max-peers`.
- Per-peer attempt-state with exponential backoff (15 / 30 / 60 /
  120 s, max 5 attempts) so transient dial failures retry.
- 15 s manage tick re-queues unconnected peers from the table —
  bee's analogue of the Kademlia manage loop.
- Concurrent inbound hive responders no longer race the dialer
  (`peers_mtx`).

### Spec §1.5 origin retry on retrieval failure (Phase 5c)

- `connectionsSortedByDistance(addr)` returns connected peers in
  XOR-asc order to the chunk address.
- `retrieveChunkIterating(addr)` walks that list. On
  `error.PeerError` (peer's `Delivery{Err}`) or stream-reset, falls
  through to the next-closest peer — exactly the *"next peer
  candidate"* loop in §1.5 of the Swarm Protocol Specification.
- Bee's go origin does up to 32 retries (`maxOriginErrors`); zigbee
  does up to N where N = number of connected peers. Multiplies the
  effective forwarding-Kademlia "starting points" available.

### 30 s per-attempt timeout (Phase 5d)

- Watchdog thread per attempt using `std.Thread.Condition.timedWait`.
  The happy path wakes immediately on `signalDone()`; only a hung
  peer eats the full 30 s.
- New `Stream.cancel()` in yamux: sets the local reset flag,
  broadcasts both condvars, sends RST. Used by the watchdog to
  forcibly unblock a hung read.
- Matches bee's `RetrieveChunkTimeout = 30 * time.Second` in
  `pkg/retrieval/retrieval.go`.

### Chunk-tree (joiner) reassembly for multi-chunk files (Phase 5e)

- New `src/joiner.zig`: walks the bee chunk-tree depth-first.
  Leaf if `span ≤ payload.len`, otherwise payload is concatenated
  32-byte child addresses (branching factor 128). Recurses,
  concatenates leaf payloads.
- `MAX_REASONABLE_SPAN = 1 TiB` sanity check rejects implausibly
  large spans (catches feeding a SOC reference into the joiner —
  returns `error.LikelySocReference` rather than OOM-ing).
- Wired into `GET /bzz/<reference>`. Verified live against
  bee `POST /bytes`-uploaded files: 1500 B and 10 000 B
  byte-identical round-trips.

### Mantaray manifest walker (Phase 7b — the headline)

- New `src/mantaray.zig` (~340 lines): full v0.2 (and v0.1) decoder.
  Header parse (32 B obfuscation key + 31 B version hash + 1 B
  refSize), XOR de-obfuscation, fork iteration with metadata-on-fork
  JSON decoding.
- `lookup(node, path)` matches bee's `LookupNode`: always recurses
  into the fork's child after a prefix match; returns the matched
  node's `entry`.
- `lookupForkMetadata(root, "/")` reads bee's root-level
  metadata where bee parks `website-index-document`.
- `resolveDefaultFile(root)` is bee's `bzz.go` flow: read the `"/"`
  fork's `website-index-document` value → look up that suffix from
  the root → return the matched node's entry → hand to the joiner.
- Wired into `/bzz/<ref>` with auto-detection: if root chunk has the
  mantaray header, walk the manifest first; otherwise treat the ref
  as a CAC tree root.
- **Result: zigbee's `/bzz/<manifest-ref>` is byte-identical to
  bee's `/bzz/<ref>/`** — both styles of reference (`POST /bytes`
  raw upload and `POST /bzz` manifest-wrapped upload) now
  transparently work.

## Bugs found and fixed during this release

| Bug | Symptom | Fix |
|---|---|---|
| One-shot dial sometimes only got 1 peer despite hive broadcasts | Sample variance | Per-peer attempt count + exponential backoff + manage tick re-queue |
| `/retrieve` returned 502 the first time, sometimes worked next | Single-peer retrieval; spec §1.5 mandates origin-retry | Iterate `connectionsSortedByDistance` on Err / reset / timeout |
| Hung peer would block retrieval forever | No per-attempt timeout | Watchdog thread + `Stream.cancel()` |
| Every intermediate chunk falsely failed CAC validation | `bmt.Chunk.init(payload)` defaulted span to `payload.len`; for intermediates the real span is the total subtree size | Use the wire-decoded span when computing the BMT address (`retrieval.zig`) |
| `/bzz` returned `error.OutOfMemory` on SOC references | Joiner read first 8 bytes of SOC identifier as span → 9.3 quintillion → OOM | Added 1 TiB span ceiling + `LikelySocReference` |
| `/bzz` on bee `/bzz?name=foo`-uploaded references returned the manifest's binary bytes | No manifest walker | New `src/mantaray.zig`; auto-detect mantaray header on root chunk and resolve |
| Walker initially returned the fork's ref (sub-manifest chunk address) instead of the child's entry (file ref) | First-pass mantaray bug | Always recurse into the fork's child after matching the prefix, return the loaded child's entry — same as bee's `LookupNode` |
| Walker rejected `ref_bytes_size = 0` | Bee uses 0-size for terminal manifest nodes that only carry metadata-on-parent-fork | Allow 0; skip forks at `ref_size=0` (matches bee's UnmarshalBinary v0.2) |

## Numbers

- **~7,700** lines of Zig in **27** modules in `src/`.
- **62** unit tests, **62** passing (`zig build test`).
- **1** vendored C dependency: `libsecp256k1`.
- **0** Go or Rust dependencies.
- Live verification:
  - 1500 B file (raw `/bytes` upload) → byte-identical via `/bzz/<ref>`.
  - 10 000 B file (raw `/bytes` upload, 1 root + 2 leaves) → byte-identical via `/bzz/<ref>`.
  - 2742 B file (mantaray-wrapped `/bzz?name=…` upload) → byte-identical via `/bzz/<manifest-ref>`.
  - Multi-peer fan-out on testnet bootnode `167.235.96.31:32491`: connects to 4–6 peers in 15–30 s.
  - Forwarding-Kademlia retrieval with origin retry: chunks unreachable from one peer's neighbourhood are recovered by trying the next-closest connected peer.

## What still doesn't work

- **SWAP cheques** (`/swarm/swap/1.0.0/swap`). Without them, bee's
  per-peer disconnect threshold (`apply debit: disconnect threshold
  exceeded`) caps unpaid retrieval at ~25–30 chunks per peer per
  session. Daemon's multi-peer iteration extends the budget to
  N × that, but it's still finite. **This is the only thing
  bounding "retrieve any file" today.** Phase 6.
- **No push.** `POST /bytes` and `POST /bzz` aren't implemented;
  needs postage stamps + on-chain integration.
- **No SOC validation.** Single-Owner Chunks pass through with a
  logged CAC mismatch. The joiner's span ceiling catches the most
  common error of feeding an SOC-rooted reference into the joiner.
- **No `/bzz/<ref>/<path>` HTTP routing yet.** The mantaray walker
  supports paths; the HTTP route doesn't yet parse the trailing
  path component out of the request.
- **No encrypted-chunk references** (`refLength = 64`).
- **No persistent identity.** Each restart generates a fresh libp2p
  key and overlay, so bee's per-peer accounting state resets. Useful
  for testing, not what a real client should do.

## CLI surface

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
                        GET /retrieve/<hex>   — fetch a single chunk
                        GET /bzz/<reference>  — fetch a full file
                                                (manifest-aware)
                        GET /peers            — connected-peer JSON
```

## Documentation

- `README.md` — overview + TL;DR.
- `USAGE.md` — copy-pasteable scenarios (testnet bootnode,
  end-to-end with local bee, mainnet, single-chunk fetch, HTTP API
  reference).
- `ARCHITECTURE.md` — ultra-light-client model, retrieval threading
  diagram, the accounting wall.
- `PLAN.md` — multi-phase roadmap.
- `STATUS.md` — operational snapshot.
- `RELEASE_NOTES_0.1.md` — original 0.1 release.
- `RELEASE_NOTES_0.3.md` — this file.

## Build

```bash
zig build           # → zig-out/bin/zigbee
zig build test      # → 62/62
```

Requires Zig 0.15.x and a C toolchain (for the vendored libsecp256k1).

## Acknowledgements

zigbee borrows protocol details from `bee/v2.7.x` (Apache-2.0 / BSD-3-Clause)
and uses test vectors from cacophony (BSD-3-Clause) and flynn/noise (MIT).
The mantaray decoder is a Zig translation of bee's
`pkg/manifest/mantaray/{node.go,marshal.go,walker.go}`.
