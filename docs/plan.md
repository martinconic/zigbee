# zigbee — implementation plan

A pure-Zig, standalone, network-interoperable Swarm client.

This document supersedes `gemini_implementation_plan.md`. The original is kept
for history; everything below is the operational plan we work from.

---

## 1. Goal

Build a Swarm Bee client in pure Zig that:

- Connects directly to the live Swarm network (testnet first, mainnet later).
- Is interoperable with `bee` (Go) and other clients — no FFI to other libp2p
  stacks. Pure Zig + a vendored C `secp256k1` for now.
- Is standalone: a real network participant, not a wrapper around an HTTP API.
- Is delivered in stages, with each stage producing a node that does something
  useful and is verified against a live `bee` peer.

Pure Zig is non-negotiable. The trade-off — multi-month timeline — is accepted.

## 2. Non-goals (for the first delivery)

These are deferred until *after* the light node works end-to-end. Listed here
so the scope of v0.1 / v0.2 stays disciplined.

- Full-node mode (storage incentives / chequebook / redistribution).
- WebSocket and QUIC transports. **TCP only.**
- TLS / autotls / `/ws` bootnodes.
- NAT traversal, hole punching, AutoNAT.
- Any kind of GUI, metrics export, OpenTelemetry tracing.
- Optimisations for "small hardware". We chase correctness first; size second.

**No longer non-goals (now in scope, delivered in zigbee 0.2):**
- ~~An HTTP REST API.~~ Daemon mode serves `/retrieve`, `/bzz`, `/peers` on
  127.0.0.1:9090 (per `--api-port`).
- ~~Multi-peer connection management at scale.~~ Daemon auto-dials
  hive-discovered peers up to `--max-peers`, with retry/backoff and a
  manage tick.

**SWAP** stays a non-goal in name but is the next concrete blocker — without it
zigbee can only retrieve ~25–30 chunks per peer per session before bee's
disconnect threshold kicks in. Phase 6.

## 3. Architectural commitments

These are decided now so we stop drifting.

| Concern | Decision | Rationale |
|---|---|---|
| Concurrency | OS threads + `std.Thread.Mutex` / `Condition` | Zig has no green threads; a reactor is its own project. Simplicity first. |
| I/O | Blocking sockets; one read-loop thread per connection, one write mutex per stream | Adequate for a few peers; revisit when we have profiling data. |
| Allocator | One `Allocator` passed into every constructor; arena per request inside protocol handlers | Stop stack-allocating 64KB everywhere. |
| Storage (Phase 5) | Flat-file chunk store keyed by hex prefix dirs; one file per chunk | Replaceable later. Avoids vendoring an LSM tree on day one. |
| Cryptography | `std.crypto` + vendored `libsecp256k1` (C) | Pure-Zig secp256k1 doesn't exist at production quality yet. Documented exception. |
| Protobuf | Hand-written for the few messages we need; revisit if it exceeds ~10 messages | Generators are a yak. |
| Logging | One thin `log.zig` with levels (`err`/`warn`/`info`/`debug`/`trace`) and topic strings; no print statements in protocol code | Bee uses structured logging too — easier to compare side-by-side. |
| Errors | Zig error sets per module; never `anyerror` in public APIs | Consistent diagnostics. |
| Tests | Two tiers: in-process unit/KAT tests run by `zig build test`; integration tests that boot a `bee` node and run zigbee against it (gated by an env var so CI can opt in) | Unit tests caught nothing about the Noise drift bug — that's the lesson. |
| Build | `build.zig` + `build.zig.zon`; one binary `zigbee`; modules: `crypto`, `multiformats`, `noise`, `yamux`, `multistream`, `libp2p`, `swarm` (handshake/hive/retrieval/...), `store`, `node` | Clear module boundaries from the start. |

## 4. MVP — "Light Node v0.1"

> **zigbee 0.1**: dial one testnet bootnode, complete bee's handshake,
> appear as a connected peer in `bee`'s logs with our overlay address,
> retrieve one chosen chunk from the network using `/retrieval/1.4.0`,
> validate its BMT, and write it to a local file.

That is the entire v0.1. Pushing chunks, issuing stamps, SWAP, redistribution
are all out of scope for v0.1. Shipping a node that *retrieves* is already
useful for embedded / read-only use cases.

## 5. Known protocol IDs we must speak

From the `bee` source at the time of writing (`bee/v2.7.x`):

| Protocol | libp2p ID prefix | Wire format |
|---|---|---|
| multistream-select | `/multistream/1.0.0` | varint-prefixed text + `\n` |
| Noise | `/noise` | Noise XX, Curve25519 / ChaChaPoly / SHA256, libp2p prologue: empty |
| Yamux | `/yamux/1.0.0` | hashicorp/yamux v0 frames |
| libp2p Identify | `/ipfs/id/1.0.0` | protobuf `IdentifyMessage` |
| libp2p Ping | `/ipfs/ping/1.0.0` | 32-byte echo |
| Bee handshake | `/swarm/handshake/14.0.0/handshake` | protobuf `Syn`/`Ack`/`SynAck` |
| Bee hive (peer discovery) | `/swarm/hive/1.1.0/peers` | protobuf `Peers` |
| Bee pingpong | `/swarm/pingpong/1.0.0/pingpong` | protobuf `Ping`/`Pong` |
| Bee retrieval | `/swarm/retrieval/1.4.0/retrieval` | protobuf `Request`/`Delivery` |
| Bee status | `/swarm/status/1.1.3/status` | protobuf `Snapshot` |
| Bee pushsync (post-MVP) | `/swarm/pushsync/1.3.1/pushsync` | protobuf `Delivery`/`Receipt` |
| Bee pullsync (post-MVP) | `/swarm/pullsync/1.4.0/pullsync` | protobuf — multi-stream |

Bee's stream-ID format on the wire is:
`/swarm/<name>/<version>/<stream>` — see `bee/pkg/p2p/p2p.go:230`.

## 6. Phased plan

Each phase has: scope, deliverables, validation against a real `bee` node.
A phase is **not done** until validation passes.

### Phase 0 — Noise XX correctness *(unblocks everything else)*

**Scope.** Drive `NoiseState` through published Noise_XX_25519_ChaChaPoly_SHA256
test vectors and fix the divergence that today causes AEAD authentication to
fail when talking to bee.

**Deliverables.**
- `vendor/noise-test-vectors/` with vectors from `cacophony` or `noise-c`,
  pinned to a commit.
- `src/noise_kat.zig` with a parametrised test that, for each vector:
  - replays the recorded ephemeral keys (overrides `EphemeralKeypair.generate`
    via a test-only hook),
  - feeds in the recorded payloads,
  - asserts each emitted ciphertext, `h`, `ck`, and final transport keys
    match byte-for-byte.
- A clean `NoiseState.init` whose two speculative `mixHash` calls (added
  during the failed bee interop) are either justified by the KAT or removed.
- Doc comment at the top of `noise.zig` linking to the spec section that
  governs each method.

**Validation.**
- KAT tests pass byte-for-byte.
- The pre-existing localhost initiator↔responder roundtrip still passes.
- *Bee interop:* `zig-out/bin/zigbee` against a `bee start --config testnet.yaml`
  no longer fails at decrypting the responder's `s`; the next failure (if any)
  is in a layer above Noise.

**Estimate.** 1–2 days.

---

### Phase 1 — libp2p baseline

**Scope.** Everything that's mandatory before *any* application protocol works.

**Sub-tasks.**

1. **Multiaddr** (`src/multiformats/multiaddr.zig`)
   - Parse and stringify at minimum: `/ip4/<addr>/tcp/<port>`, with optional
     `/p2p/<peer-id>` suffix; `/dnsaddr/<name>`; `/dns4/<name>/tcp/<port>`.
   - Round-trip tests with hand-crafted byte vectors and the textual form.

2. **Multihash & PeerID** (`src/multiformats/multihash.zig`, `src/libp2p/peer_id.zig`)
   - Multihash encode/decode (we only need `identity` (0x00) for inline keys
     and `sha2-256` (0x12) for hashed keys).
   - PeerID derivation:
     - Marshal libp2p `PublicKey` proto (key_type=3 Secp256k1, 33-byte
       compressed key — already in zigbee).
     - PeerID = multihash(sha2-256, marshalled) wrapped as a multihash, or
       `identity` multihash for short keys (≤ 42 bytes).
     - Encode/decode as base58btc (the legacy form bee uses today).

3. **DNS resolution** (`src/net/dns.zig`)
   - Minimal stub resolver: TXT lookup of `_dnsaddr.<host>` returning
     `dnsaddr=...` records, parsed back into multiaddrs.
   - Implementation: blocking, native `getaddrinfo` for A records; for TXT,
     speak DNS-over-UDP/53 directly using `std.posix` and parse RFC 1035 wire
     format. (System resolver in Zig stdlib does not expose TXT.)
   - Tested against `_dnsaddr.sepolia.testnet.ethswarm.org` → ≥ 1 multiaddr.

4. **multistream-select** (`src/libp2p/multistream.zig`)
   - Full `select(protocols)` and `respond(supported_protocols)`.
   - Handle `na`, `ls`. We don't yet need simultaneous open.
   - Read loop must handle partial TCP reads (already fixed in `readLengthPrefixed`,
     but the API gets reorganised here).

5. **Yamux v0** (`src/yamux.zig` rewrite)
   - Frame types: Data, WindowUpdate, Ping, GoAway.
   - Per-stream state: `init` / `syn-sent` / `syn-recv` / `established` /
     `local-closed` / `remote-closed` / `closed` / `reset`.
   - Per-stream send/receive windows; default 256 KiB initial window.
   - Background read loop dispatches frames into per-stream queues protected
     by `Mutex` + `Condition`.
   - `openStream()` / `acceptStream()` / `Stream.read` / `Stream.write` /
     `Stream.close` / `Stream.reset`.
   - Pings answered automatically; outgoing ping every 30 s as keep-alive.
   - GoAway sent on shutdown.
   - Tests: round-trip multiple concurrent streams locally; partial reads;
     window-update flow; ping/ack.

6. **libp2p Identify** (`src/libp2p/identify.zig`)
   - Implement responder side: when peer dials `/ipfs/id/1.0.0`, reply with
     our `IdentifyMessage` (publicKey, listenAddrs, observedAddr, protocols,
     protocolVersion, agentVersion).
   - Implement initiator side: dial `/ipfs/id/1.0.0`, decode peer's payload,
     extract their reported listen addresses and supported protocols.

7. **libp2p Ping** (`src/libp2p/ping.zig`)
   - 32-byte echo. Used by bee's reachability checker.

8. **Connection manager** (`src/libp2p/host.zig`)
   - One thread per inbound connection; one thread per outbound connection.
   - Owns the Noise + Yamux session; multiplexes protocol handlers by
     multistream-select on each stream.
   - `Host.dial(multiaddr) -> *Conn`; `Host.handle("/swarm/.../...", handler)`.

**Validation.**
- Dial a real bee testnet node; complete `/ipfs/id/1.0.0`; print decoded
  `IdentifyMessage` showing bee's agent version (e.g. `bee/2.7.2-...`).
- Bee's logs show our zigbee node connecting and identifying.
- All Phase 1 sub-modules have unit tests.

**Estimate.** 2–3 weeks.

---

### Phase 2 — Bee handshake `/swarm/handshake/14.0.0`

**Scope.** Implement Bee's application-level handshake. Without this, bee
disconnects right after libp2p Identify.

**What it does.**
- Both peers exchange `Syn`, `Ack`, `SynAck` protobuf messages over a
  dedicated Yamux stream.
- Each side sends:
  - its overlay address (32 bytes),
  - underlay address (multiaddr including peer ID),
  - signature binding overlay to underlay using the **chain (Ethereum)** key,
  - `network_id`, `full_node` flag, `nonce` (the same nonce that goes into
    overlay derivation),
  - welcome message (string).
- Each side verifies the other's overlay binding signature, network ID match,
  and (if it cares) full-node flag.

**Sub-tasks.**

1. Read `bee/pkg/p2p/libp2p/internal/handshake/handshake.go` end-to-end.
   Capture exact wire format, signing message format, and validation rules
   in a doc comment in `src/swarm/handshake.go`.
2. `src/swarm/handshake.zig` — protocol implementation.
3. Hook handshake into the Phase 1 connection-establishment flow.
4. Reject peers with mismatched network ID; persist verified peer info into
   a peer store.

**Validation.**
- After connecting to a testnet bootnode, bee's logs show
  `"handshake finished for peer (outbound)" peer_address=<our overlay>`.
- Reverse: bee dials zigbee (when zigbee listens), bee's handshake completes.

**Estimate.** 1 week.

---

### Phase 3 — Hive `/swarm/hive/1.1.0`

**Scope.** Parse the `Peers` broadcasts we already receive (read-and-discard
hive stub is in place — see Phase 2.6) into validated peer records, persist
them in a peer table, and add the initiator side so we can actively request
batches.

**Bee does NOT use libp2p's Kademlia DHT.** It has its own `/hive/` protocol
that exchanges `Peers { peers: [BzzAddress, …] }` messages, where each
`BzzAddress` is the same protobuf used in the application handshake:
`{ underlay: bytes, signature: bytes, overlay: bytes, nonce: bytes }`.

**Sub-tasks.**

1. **Pull BzzAddress decode/verify out of `bee_handshake.zig`** into a shared
   `bzz_address.zig` module. Reuse from both modules.
2. **`src/hive.zig` extension** — replace the count-only stub with a real
   parser that yields `[]const BzzAddress` and validates every entry's
   signature using `identity.recoverEthereum` + `identity.overlayFromEthereumAddress`.
3. **`src/peer_table.zig`** — minimal peer table:
   - `std.AutoHashMap([32]u8, PeerEntry)` keyed by overlay
   - 31-bin Kademlia structure indexing peers by leading-bit proximity to
     our own overlay (for closest-peer queries in Phase 4)
   - one peer per bin entry initially (`MaxBin = 31`)
   - eviction policy: replace on disconnect
4. **Initiator side of hive** — open a stream, do multistream-select +
   header exchange, send our `Peers` (empty for now), read peer batches
   back. Trigger this immediately after handshake completes against bee.

**Validation.**
- After 30 s connected to one bootnode, our peer table has ≥ 10 peers.
- We can dump the table and pick the closest peer for a given chunk
  address (no actual retrieval — that's Phase 4).

**Status of code we already have that helps Phase 3.**
- ✅ Signature recovery (`identity.recoverEthereum`) and overlay derivation
  (`identity.overlayFromEthereumAddress`) — used by the bzz handshake;
  reusable as-is.
- ✅ `bee_handshake.parseBzzAddress` exists as a private helper; lift to
  the new shared module.
- ✅ `multiaddr.Multiaddr.peerIdBytes()` — extracts the libp2p PeerID
  multihash from a `/p2p/` component when we want to dial a peer we
  learned about via hive.
- ✅ Headers exchange + delimited framing in `swarm_proto.zig`.

**Estimate.** 2–4 days for table + initiator + validation.

---

### Phase 4 — Retrieval `/swarm/retrieval/1.4.0`  *(MVP DELIVERABLE)*

**Scope.** Retrieve a chunk by address from the network.

**Sub-tasks.**

1. `src/swarm/retrieval.zig` — protobuf `Request`/`Delivery`.
2. Routing: pick the closest connected peer (by XOR distance on overlay) to
   the requested chunk address.
3. Forward retrieval: if a peer asks us for a chunk we don't have, we
   forward to *our* closest peer — but for v0.1 we just answer "not found".
4. Validate received chunk's BMT (already implemented) before returning.
5. CLI: `zigbee retrieve <chunk-hex-address> [--out file]`.

**Validation.**
- Pick a chunk address that's known to exist on the testnet
  (e.g. one we look up via a running `bee`'s API).
- `zigbee retrieve <addr>` produces the same bytes as bee's
  `GET http://127.0.0.1:1633/chunks/<addr>`.
- **This is zigbee 0.1.** Tag a release.

**Estimate.** 1–2 weeks.

---

### Phase 5 — Local storage

**Scope.** A persistent chunk store so retrieved chunks (and later, our own
data) live across restarts.

**Sub-tasks.**

1. `src/store/flatfs.zig` — chunk store keyed by `<addr_hex_first_2_chars>/<addr_hex>`.
2. Atomic write via tempfile + rename.
3. Cache layer in front (LRU bounded by chunk count).
4. Stats: count, total size.

**Validation.**
- Retrieve a chunk; restart zigbee; serve same chunk from the store
  without re-fetching.

**Estimate.** 1 week.

---

### Phase 6 — Pushsync `/swarm/pushsync/1.3.1`

**Scope.** Push a chunk into the network.

Requires postage stamps. For Phase 6 we do not issue our own stamps; we accept
a stamp blob on the CLI (e.g. one provided by an external `bee` for testing).

**Sub-tasks.**

1. `src/swarm/postage.zig` — stamp parsing + signature validation.
2. `src/swarm/pushsync.zig` — protobuf `Delivery`/`Receipt`.
3. Forward to closest peer; collect receipts.
4. CLI: `zigbee push <file> --stamp <hex-stamp>`.

**Validation.**
- Push a chunk, retrieve it back via Phase 4 from a different peer.

**Estimate.** 2 weeks.

---

### Phase 7 — Pullsync, status, pingpong

**Scope.** The remaining read-side application protocols. Status and pingpong
are simple; pullsync is multi-stream and stateful.

Defer detailed sub-tasks until Phase 6 lands.

**Estimate.** 2–3 weeks.

---

### Phase 8+ — Eth RPC, postage issuance, SWAP, redistribution

These convert the light node into a full node. Out of scope for the first
delivery; tackled only after Phases 0–6 are stable.

A separate planning document will be written when we get there.

## 7. Cross-cutting concerns

### Test strategy

| Tier | Trigger | Purpose |
|---|---|---|
| Unit | `zig build test` | Pure logic: codecs, hashes, BMT, multiaddr, etc. |
| KAT | `zig build test` | Spec-vector tests for Noise, Yamux, multihash, multiaddr. **Mandatory before declaring a protocol layer "done".** |
| Local roundtrip | `zig build test` | initiator↔responder over loopback for stateful protocols. |
| Bee interop | `ZIGBEE_INTEROP=1 zig build interop` | Boot a `bee` node, run zigbee against it, assert behaviour. Skipped by default; required green before tagging a release. |

### Layout

The plan originally proposed `multiformats/`, `libp2p/`, `swarm/`, `store/`
sub-directories. In practice we kept everything flat in `src/` while iterating;
re-organising into sub-directories is a deferred cleanup task, not a
priority. The current layout (as of zigbee 0.2 — daemon + chunk-tree
retrieval) is:

```
zigbee/
├── build.zig
├── build.zig.zon
├── vendor/
│   └── secp256k1/                  (C dep, recovery module included)
├── src/
│   ├── main.zig                    (CLI: zigbee [resolve|retrieve|daemon])
│   ├── root.zig                    (module entry)
│   │
│   ├── crypto.zig                  (Keccak256 helpers)
│   ├── bmt.zig                     (chunk address — bee golden-vector tested)
│   ├── identity.zig                (secp256k1 keys, overlay derivation, Eth-style sign/recover)
│   │
│   ├── proto.zig                   (varint + libp2p PublicKey + NoiseHandshakePayload + NoiseExtensions)
│   ├── multiaddr.zig               (text↔binary, ip4/tcp/dns*/p2p)
│   ├── dnsaddr.zig                 (RFC 1035 DNS-over-UDP TXT, recursive /dnsaddr resolution)
│   │
│   ├── noise.zig                   (XX initiator + responder, peer libp2p key plumbed out)
│   ├── noise_kat.zig               (cacophony XX vector + flynn/noise oracle)
│   ├── libp2p_key.zig              (KeyType dispatch + P-256 SPKI parser/verifier)
│   ├── peer_id.zig                 (libp2p PeerID multihash; /ip4/.../p2p/<id> builders)
│   │
│   ├── multistream.zig             (multistream-select 1.0.0 client + server)
│   ├── yamux.zig                   (full session: per-stream state, reader thread, accept/open, ACK/FIN/RST/Ping/WindowUpdate, Stream.cancel for retrieval-timeout watchdog)
│   │
│   ├── identify.zig                (/ipfs/id/1.0.0 responder + initiator)
│   ├── ping.zig                    (/ipfs/ping/1.0.0 echo)
│   │
│   ├── swarm_proto.zig             (shared bee-stream framing: readDelimited, writeDelimited, exchangeEmptyHeaders, exchangeEmptyHeadersInitiator)
│   ├── bee_handshake.zig           (/swarm/handshake/14.0.0 — Syn/SynAck/Ack, BzzAddress signing+recovery)
│   ├── bzz_address.zig             (BzzAddress decode + verify; UnderlayIterator for bee's 0x99-prefixed multi-underlay list)
│   ├── peer_table.zig              (HashMap by overlay + 32 Kademlia bins + closestTo)
│   ├── pricing.zig                 (/swarm/pricing/1.0.0 — responder + initiator)
│   ├── hive.zig                    (/swarm/hive/1.1.0 — responder; populates peer_table)
│   ├── retrieval.zig               (/swarm/retrieval/1.4.0 initiator; CAC first then SOC validation, ChunkAddressMismatch if neither)
│   ├── soc.zig                     (Single-Owner Chunk parser+validator — id‖sig‖span‖payload, EIP-191-prefixed sig over keccak256(id ‖ inner_addr); bee golden-vector tested)
│   ├── joiner.zig                  (chunk-tree reassembler — walks span/payload tree, branching=128)
│   │
│   ├── connection.zig              (heap-allocated Connection: TCP+Noise+Yamux; dial(); startAcceptLoop())
│   └── p2p.zig                     (the host: multi-peer connection list, hive-fed auto-dialer with retry+backoff, manage tick, XOR-asc retrieval iteration, 30s watchdog, HTTP API for /retrieve, /bzz, /peers)
```

**Originally planned but not yet here** (introduce when needed):
```
│   ├── swarm/swap.zig               (Phase 6 — SWAP cheques)
│   ├── swarm/postage.zig            (Phase 9 — pushsync stamps)
│   ├── swarm/pushsync.zig           (Phase 9)
│   ├── swarm/pullsync.zig           (Phase 10)
│   ├── swarm/manifest.zig           (Phase 7 — mantaray walk for /bzz/<ref>/<path>)
│   ├── store/flatfs.zig             (Phase 8 — local chunk store)
│   └── log.zig                      (proper levels + topics; replaces std.debug.print)
```

### Logging

- Levels: `err`, `warn`, `info`, `debug`, `trace`.
- Per-module topic strings (`noise`, `yamux`, `swarm.handshake`, ...).
- Output via `std.log` with a runtime-configurable threshold from
  `--verbosity 0..5` matching bee's convention.
- **No `std.debug.print` in protocol code.** Existing prints in `noise.zig`
  and `yamux.zig` are removed when the corresponding phase is touched.

### Error handling

- Each module declares its own `Error` set.
- Public functions return `!T`; never `anyerror!T`.
- Connection-fatal errors ⇒ tear down the Yamux session with a `GoAway`.
- Stream-fatal errors ⇒ Yamux `RST` on that stream only.

### Concurrency boundaries

- The Yamux session owns the underlying `NoiseStream` and serialises writes.
- Each accepted Yamux stream runs in its own thread for the duration of a
  protocol exchange. Threads pulled from a fixed-size pool to bound resources.
- The peer table is a single struct guarded by `Mutex`.
- The chunk store is filesystem-atomic (tempfile + rename); no in-memory lock.

### Measurement and profiling

- Track binary size at every phase boundary (`ls -l zig-out/bin/zigbee`).
- Track RSS during interop tests.
- These numbers go into the section below.

## 8. Risks and open questions

| Risk | Mitigation |
|---|---|
| Pure-Zig secp256k1 doesn't exist | Vendored libsecp256k1 stays. Documented exception to "pure Zig". |
| Bee changes its protocol versions | We pin to a specific bee tag for interop testing and bump deliberately. |
| Yamux flow control bugs are subtle | Cover with multi-stream interop tests early; the local roundtrip is not enough. |
| Connection-per-thread doesn't scale | Acceptable up to a few dozen peers. Replaced with a poll/io_uring reactor only after profiling demands it. |
| Light-node mode in bee may still expect us to support stamps & accounting | Investigate during Phase 2 — we may need a stub that says "I'm too light to settle" gracefully. |
| Postage stamps require chain reads even to *validate* | For Phase 6 we accept stamps as a blob on stdin; chain integration is Phase 8+. |

## 9. Tracking

Phase status lives in this file. Update the table when a phase enters
`in progress` or `done`.

| Phase | Status | Notes |
|---|---|---|
| 0 — Noise KAT fix | **done** | Cacophony KAT + flynn/noise oracle KAT + live bee testnet interop. Three bugs fixed: KeyType enum (2=Secp256k1, not 3), bee libp2p uses ECDSA-P-256 (added std.crypto.sign.ecdsa.EcdsaP256Sha256 verifier + SPKI parser in src/libp2p_key.zig), and signature verification now uses raw message (not prehash). |
| 1 — libp2p baseline | **done** | All seven sub-tasks complete. Multistream-select, full Yamux session (concurrent), libp2p Identify (responder + initiator), libp2p Ping (responder + initiator), multiaddr parser (text↔binary, ip4/tcp/dns*/p2p), /dnsaddr DNS-over-UDP resolver. Live tested against bee testnet — full Identify exchange, 16 protocols enumerated, 4 testnet bootnode multiaddrs resolved from /dnsaddr. |
| 2 — Bee handshake | **done** | Live bee accepts us: `"handshake finished for peer (inbound)" peer_address=<our 32-byte overlay>` and our welcome message. Required: ethereum-style signRecoverable + recoverEthereum (identity.zig), libp2p PeerID multihash (peer_id.zig), BzzAddress signing (bee_handshake.zig), plumbing peer libp2p key through Noise. |
| 2.5 — pricing stub | **done** | Read-and-discard `/swarm/pricing/1.0.0/pricing` responder; refactored shared bee-stream framing into `src/swarm_proto.zig` (`exchangeEmptyHeaders`, `readDelimited`, `writeDelimited`). |
| 2.6 — hive stub | **done** | Read-and-discard `/swarm/hive/1.1.0/peers` responder. Bee tracks us as a real connected peer in `/peers`. |
| ~~swap stub~~ | dropped | Bee's `swap.init` is internal-only; bee never opens swap against us during normal operation. Real SWAP cheque exchange moved to Phase 6 (post-MVP). |
| 3 — Hive (real) | **done** | `bzz_address.zig` (decode + verify + non-verifying decode), `peer_table.zig` (hashmap + 32 Kademlia bins + `closestTo`), real hive responder. Key finding: bee's hive *resigns* — strips underlays after signing — so the wire signature can't be re-verified end-to-end against the broadcast underlay. Hive entries are advisory; verified only on direct handshake. |
| 4 — Retrieval (MVP) | **done — zigbee 0.1** ✅ | `zigbee retrieve <hex-addr> -o <file>` retrieves a chunk end-to-end over the Swarm network. `cmp` byte-for-byte against bee's `/chunks/<addr>` REST API → IDENTICAL. SOC validation logged but not yet enforced. |
| 4.1 — `--peer` / `--network-id` flags | done | zigbee can dial any TCP-reachable bee, including testnet bootnodes resolved via `/dnsaddr/`. |
| 5 — Daemon mode + multi-peer + tree retrieval | **done — zigbee 0.2** ✅ | See sub-phases below. (Rolled into 0.3 release notes; never tagged separately.) |
| 5a — Daemon mode + multi-peer + retrieval API | done | Heap-allocated `Connection` (`src/connection.zig`); `P2PNode` holds `connections: ArrayList(*Connection)` plus a hive-fed auto-dialer; HTTP API on 127.0.0.1:9090 with `GET /retrieve/<hex>` and `GET /peers`. |
| 5b — Dialer reliability + manage tick | done | Per-peer attempt-state (count + last-attempt time) replaces one-shot `attempted` set; failed dials retry with exponential backoff (15/30/60/120 s, max 5 attempts). Manage tick every 15 s re-queues unconnected peers from the table — bee's analogue of the kademlia manage loop. Added `peers_mtx` for safe concurrent reads. |
| 5c — Iterate connected peers on retrieval failure | done | Spec §1.5: "If the response message contains a non empty Err field the requesting node closes the stream and then can re-attempt retrieving the chunk from the next peer candidate." Bee's go origin does up to 32 attempts (`maxOriginErrors`). Zigbee now iterates `connectionsSortedByDistance(addr)` on `error.PeerError` / `error.StreamReset`, returning 200 on first success or 502 only after exhausting all candidates. |
| 5d — Per-attempt retrieval timeout (30 s) | done | Watchdog thread per attempt using `std.Thread.Condition.timedWait`; on timeout calls new `Stream.cancel()` (yamux RST + signal recv/send condvars). Matches bee's `RetrieveChunkTimeout = 30s` in `pkg/retrieval/retrieval.go`. Happy path wakes immediately on `signalDone()`. |
| 5e — Chunk-tree (joiner) traversal for files >4 KB | done | New `src/joiner.zig`: walks span/payload structure depth-first, leaf if `span ≤ payload.len`, otherwise payload is concatenated 32-byte child addresses (branching factor 128). Recurses, concatenates leaf payloads. Sanity-bounds span to 1 TiB to detect SOC-fed-as-CAC (`LikelySocReference` error). Wired into `GET /bzz/<reference>`. **Found and fixed a CAC validation bug in `retrieval.zig`** — `bmt.Chunk.init(payload)` defaulted span to `payload.len`; for intermediate chunks the real span is the total subtree size. Live verified: 1500 B + 10 000 B byte-identical round-trips through a local bee. |
| 7a — Manifest gotcha docs | done | README + usage.md call out the bee `/bytes` vs `/bzz` distinction and the manifest indirection. |
| 7b — Mantaray manifest walker | **done — zigbee 0.3** ✅ | `src/mantaray.zig` implements XOR de-obfuscation, v0.1/v0.2 header parse, fork iteration with metadata-on-fork JSON decode, and `lookup` + `resolveDefaultFile` matching bee's `bzz.go` flow. Verified byte-identical to `bee /bzz/<ref>/`. See [`release-notes/0.3.md`](release-notes/0.3.md). |
| 8 — Bee-compatible read-only HTTP API | **done — zigbee 0.4** ✅ | `/health`, `/readiness`, `/node` (`beeMode: ultra-light`), `/addresses`, `/peers`, `/topology`, `/chunks/<addr>`, `/bytes/<ref>`, `/bzz/<ref>/<path>`. All four storage endpoints verified byte-identical to bee. See [`release-notes/0.4.md`](release-notes/0.4.md). |
| 9 — Strategy lock-in | **done — 2026-04-28** ✅ | Strategic conversation following 0.4 release. Roadmap agreed: 0.5 retrieval-maturity → 0.6 push → 0.7 embedded → 0.8+ browser. Chain integration treated as per-target outer ring (browser via wallet, server via own RPC, embedded via pre-flashed credential). Captured in [`strategy.html`](strategy.html). |
|  | | |
| **0.4.1 patch** | **done — zigbee 0.4.1** ✅ | All three sub-patches landed and tagged. See [`release-notes/0.4.1.md`](release-notes/0.4.1.md). |
| 0.4.1a — Persistent libp2p identity | done | `Identity.loadOrCreate` writes 64-byte file (32-byte secp256k1 key ‖ 32-byte bzz nonce) atomically to `~/.zigbee/identity.key`; CLI `--identity-file <path>` (or `:ephemeral:` to opt out). Fixes "fresh accounting state on every restart" + stable overlay across reboots. |
| 0.4.1b — Dead-connection pruning | done | `Connection.dead: atomic.Value(bool)` set via `defer` on accept-loop exit; `P2PNode.pruneDeadConnections()` (two-phase reaper) called from manage tick. Manage tick moved BEFORE the connectionCount gate (otherwise dead conns inflated the count and kept the dialer asleep). `connectionCount` / `closestConnectionTo` / `connectionsSortedByDistance` / `handlePeersBee` all filter dead. |
| 0.4.1c — SOC validation | done | New `src/soc.zig`. Retrieval tries CAC first then SOC; mismatch returns `ChunkAddressMismatch` (was: pass-through unverified). Non-obvious EIP-191 wrinkle: bee's `crypto.Recover` applies the prefix internally, so signature is over `keccak256("\x19Ethereum Signed Message:\n32" ‖ keccak256(id ‖ inner_addr))`. Tested against bee's `pkg/soc/soc_test.go` golden vector. |
|  | | |
| **0.4.2 patch** | **done — zigbee 0.4.2** ✅ | Three smaller pending items cleared. See [`release-notes/0.4.2.md`](release-notes/0.4.2.md). |
| 0.4.2a — strip Noise XX hot-path prints | done | 10 `std.debug.print` lines removed from `processHandshakeInitiator` / `processHandshakeResponder` in `src/noise.zig`. Per-attempt `[dialer]` / `[retrieve]` logs in `p2p.zig` retained (still useful for development). Real logging refactor (X4: levels + JSON output + `--log-level` flag) still planned for early 0.6. |
| 0.4.2b — `POST /pingpong/<peer-overlay>` HTTP | done | Bee shape (`pkg/api/pingpong.go`): looks up an already-connected peer by overlay, opens a yamux stream, runs `/ipfs/ping/1.0.0`, returns `{"rtt":"<duration>"}` with Go-style duration formatting. New `formatGoDuration` helper (8 golden samples covering ns/µs/ms/s ranges). Returns 404 `{"code":404,"message":"peer not found"}` matching bee's `p2p.ErrPeerNotFound` path. |
| 0.4.2c — graceful shutdown on SIGINT/SIGTERM | done | Module-level `g_shutdown: std.atomic.Value(bool)` + `std.posix.sigaction` handler (does only the atomic store — async-signal-safe). `serveApi` wraps accept in `std.posix.poll(.., 200ms)` to re-check the flag. Hive dialer checks at top of every iteration. `daemonRun` keeps a joinable handle to the dialer thread and joins it after `serveApi` returns; existing `defer node.deinit()` then closes every live `Connection` cleanly. Bee no longer logs "broadcast failed" on our exit. |
|  | | |
| **0.5.0 — retrieval-maturity** | | **Read-side feature complete; estimate ~10 work-weeks FTE** |
| 0.5a — Local flat-file chunk store (basic LRU) | **done — landed on `main`** ✅ | `~/.zigbee/store/<2-hex>/<64-hex>` with atomic write. New `src/store.zig` (~470 lines incl. tests). Wired into `retrieveChunkIterating`: cache-first lookup, best-effort write-back on miss. CLI: `--store-path`, `--store-max-bytes` (default 100 MiB), `--no-store`. 6 unit tests. See [`release-notes/0.5.0.md`](release-notes/0.5.0.md). |
| 0.5b — Encrypted-chunk references (`refLength = 64`) | **done — landed on `main`** ✅ | New `src/encryption.zig` (~330 lines incl. tests) — keccak256-CTR segment cipher matching bee's golden vectors (`init_ctr=0` for data, `init_ctr=128` for span; disjoint keystreams). `joiner.zig` got `joinEncrypted` walking 64-byte refs (branching=64), per-ref decrypt of every chunk in the tree. `mantaray.zig` parser already ref-size agnostic; the loader adapter in `p2p.zig` decrypts 64-byte child manifest chunks before parsing. HTTP routes `/bytes/`, `/bzz/`, `/retrieve/` and CLI `retrieve` accept 128-char hex. Live-verified end-to-end against the local Go bee on Sepolia testnet — single-chunk /bytes 105 ms cold / 11 ms cached, 16 KiB multi-chunk /bytes 858 ms, encrypted /bzz manifest 1.12 s, all byte-identical. 7 new unit tests; total suite 87/87. See [`release-notes/0.5.0.md`](release-notes/0.5.0.md). |
| 0.5c — SWAP cheques (issue-only, no on-chain cashing) | **done — zigbee 0.5.0** ✅ | New `src/cheque.zig` (~425 lines) — EIP-712 typed-data signing + JSON wire format; verified byte-identical against bee's `TestSignChequeIntegration` golden vector (priv `634fb5a8…`, payout 500, chainId 1). New `src/swap.zig` (~315 lines) — `/swarm/swap/1.0.0/swap` initiator with settlement-headers parsing + `EmitCheque` protobuf. New `src/accounting.zig` (~520 lines) — per-(chequebook, peer) cumulative-payout tracker; persistent state at `<chequebook>.state.json` (B2 layout — state lives with the credential, not in `~/.zigbee/accounting/`). Dynamic cheque sizing: `delta_wei = exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction` from negotiated headers (CREDIT_TARGET_BASE_UNITS = 10M base units, ~7× bee's announced threshold). `Accounting.seedCumulative` allows wrapper-driven recovery from bee's `GET /chequebook/cheque`. New `src/credential.zig` (~155 lines) — JSON credential loader. CLI: `--chequebook PATH`. Without the flag, accounting still tracks debt (no-op issue path). 14 new unit tests; total suite 107/107. **Live-verified 2026-04-29** against deployed Sepolia chequebook `0xcc853f656ede26b73a9d9e2e710f6c506e12d6fa`: 25/25 retrievals, 8 cheques accepted (cumulative 8.16e14), zero disconnects. See [`release-notes/0.5.0.md`](release-notes/0.5.0.md). |
| 0.5.0 release | **done — zigbee 0.5.0** ✅ | release-notes/0.5.0.md, version bump 0.4.2 → 0.5.0, tag `v0.5.0`. Headline: zigbee retrieval can now SWAP-pay bee with real on-Sepolia cheques. Pre-provisioning model: chain interaction stays off the device; operator runs `06-deploy-zigbee-chequebook.sh` on a laptop, flashes credential alongside firmware. |
|  | | |
| **0.5.1 patch** | **done — zigbee 0.5.1** ✅ | New `--bootnode` flag accepts `/dnsaddr/<host>` or `/ip4/.../tcp/...` multiaddr, mirroring bee's `testnet.yaml` `bootnode:` field. zigbee resolves DNS internally, walks candidates in order on initial dial, falls through on failure. `--peer` keeps its precise meaning (dial *this exact peer*) and is mutually exclusive with `--bootnode`. 6 new unit tests; total 113/113. See [`release-notes/0.5.1.md`](release-notes/0.5.1.md). |
|  | | |
| **0.6.0 — push** | | **Read-write parity at the wire level; ~12 weeks FTE** |
| 0.6 — design context | — | **Protocol-only push, no on-chain code in zigbee proper.** Users provide a postage *batch credential* (`{batch_id, signing_key, depth, bucket_depth, valid_until}`) acquired by some other tool — bee, a stamp service, a wallet. zigbee uses the credential to *issue* stamps for chunks it pushes. See [`strategy.html` §7](strategy.html#sec-esp32) for the full breakdown. |
| 0.6a-i — Postage batch loader | not started | Read `{batch_id, key, depth, bucket_depth, valid_until}` from a JSON blob, file, or env var. ~100 lines. |
| 0.6a-ii — Stamp issuer | not started | `signStamp(batch, chunk_addr, bucket_index)` → 65-byte signature. Trivial — uses existing `identity.signEthereum`. ~50 lines. |
| 0.6a-iii — Stamp verifier | not started | Recover address from sig, check against batch owner. Useful both for receipts on chunks we *push* (verify the receipt) and for chunks we *receive* (defence-in-depth). Trivial — uses existing `identity.recoverEthereum`. ~50 lines. |
| 0.6a-iv — Bucket-index tracking + persistence | not started | Each batch has 2^bucket_depth slots per bucket; bee rejects stamps with reused indices, so we have to track usage durably. ~150 lines + persistence. |
| 0.6b — `/swarm/pushsync/1.3.1` initiator + receipt verification | not started | Mirror retrieval iteration: pick closest peer, send `Delivery{addr, data, stamp}`, read `Receipt{addr, sig, nonce}`, verify against expected storer. ~300 lines. |
| 0.6c-i — HTTP `POST /bytes` upload API | not started | Accept raw bytes, BMT-split into chunks, push each via pushsync, return CAC root reference. ~250 lines. |
| 0.6c-ii — HTTP `POST /bzz` upload API + manifest building | not started | Same as `/bytes` plus mantaray manifest construction (single-file vs directory). Stamp credential via `Swarm-Postage-Batch-Id` header or default loaded credential. ~150 lines. |
| 0.6.0 release | not started | `release-notes/0.6.0.md`, version bump, tag. Headline: zigbee can upload AND retrieve given an external batch credential. |
|  | | |
| **0.6 — provisioning-pattern catalogue (deployment guidance, not zigbee code)** | reference | Three patterns for getting a batch credential onto a deployed zigbee. None require chain code on the device. Covered in detail at [`strategy.html` §7](strategy.html#sec-esp32). |
| Pattern A — pre-flash a long-life batch | — | Buy batch with bee on a laptop, export `{batch_id, key, …}` blob, write to NVS / config file at deploy time. Best for IoT (single device, year-long deployment). |
| Pattern B — backend stamp service | — | Device fetches credential from an HTTPS endpoint at boot / before each push. Backend holds the batches and possibly buys new ones as they expire. Best for fleets. |
| Pattern C — per-chunk RPC signing | — | Device sends each chunk address to a backend signing service which returns a stamp signature; device never holds the batch key. Best when device compromise must not compromise the batch. Slow (round-trip per chunk). |
|  | | |
| **0.7.0 — embedded** | | **The runtime enablement for IoT (the headline focus); ~5 weeks ARM + ~4 weeks MCU** |
| 0.7a — ARM Linux release matrix | not started | Cross-compile vendor/secp256k1 for `arm-linux-gnueabihf` + `aarch64-linux-gnu` (also musl variants for Alpine/OpenWRT). Validate on Pi Zero W. GitHub Actions: statically-linked binaries for x86_64/armv7/arm64 on every tag. ~1 week. |
| 0.7b — ESP32-S3 spike | **planned** (re-classed from "gated" 2026-04-28 with IoT as headline focus) | FreeRTOS + lwIP + Xtensa-cross-compiled libsecp256k1; replace `std.Thread` with `xTaskCreate`; replace GPA with FreeRTOS pool allocator. Goal: retrieval + push over WebSocket on ESP32-S3 dev board. ~4 weeks. |
| 0.7.0 release | not started | `release-notes/0.7.0.md`, version bump, tag. |
|  | | |
|  | | |
| **Cross-cutting IoT items** | | **Operability concerns that span milestones; surfaced 2026-04-28 with IoT as headline focus. See [`iot-roadmap.html` §4](iot-roadmap.html#sec-cross).** |
| X1 — Resource bounds (configurable queue / buffer / cap sizes) | starts in 0.5; finalised in 0.7a | CLI flags: `--max-peers`, `--max-in-flight-chunks`, `--store-max-bytes`, `--http-max-body`. Document recommended settings per target (server / Pi / ESP32). Prevents IoT-killer "lazy let-it-grow" defaults. |
| X2 — Persistent state survives crash / power loss | folded into 0.4.1a + 0.5a + 0.6a-iv | Atomic write + journaled recovery for: identity, local store, bucket-index counters, cheque ledger. Tested by killing the process during writes. Bucket reuse after unclean reboot = silently rejected pushes. |
| X3 — Continuous cross-compilation in CI | introduce in 0.5; formalise in 0.7a | GitHub Actions matrix: `x86_64-linux-musl`, `aarch64-linux-musl`, `arm-linux-musleabihf`. Every commit. `vendor/secp256k1` rebuilt for each target. Catches Linux-isms before they pile up. |
| X4 — Production logging mode | early 0.6 | Log levels (`silent` / `error` / `info` / `debug`) + structured (one-line JSON) or human output. CLI flag `--log-level`. Daemon-mode default = `error`. A talkative daemon fills an MCU log buffer in minutes. |
| X5 — Static-link path | 0.7a | Statically link against musl + vendored libsecp256k1. Single-file `scp zigbee <device>:/usr/local/bin/` deploys. Required for Alpine / OpenWRT / busybox-based ARM Linux. |
|  | | |
| **Proof-of-concept demos** | | **End-to-end IoT scenarios under `examples/`. Each one a self-contained working build that proves the IoT use case.** |
| Demo 1 — ESP32-S3 temperature sensor → Swarm | after 0.6 + 0.7b | `examples/esp32-tempsensor/` — BME280 → ESP32-S3 → zigbee → Swarm. Pre-flashed batch credential (provisioning pattern A). One reading every 10 min. Reference printed via UART. |
| Demo 2 — Raspberry Pi Zero retrieval gateway | after 0.5 + 0.7a | `examples/pi-zero-gateway/` — Pi Zero W on local Wi-Fi, zigbee daemon serving bee-compatible HTTP API to other devices on the LAN. Local chunk store caches. Privacy-preserving small-business gateway. |
| Demo 3 — Firmware update from a Swarm reference | after 0.5 + 0.7a | `examples/firmware-update/` — embedded device boots, reads `/etc/zigbee/firmware.ref`, retrieves blob via zigbee, verifies a baked-in public-key signature, triggers reflash. Decentralised OTA. |
|  | | |
| **0.8+ — in-browser** | revisit after 0.7 | Major decisions to settle first: secp256k1 strategy (pure-Zig project vs Emscripten vs JS FFI to noble-secp256k1), transport abstraction, async event loop, Service Worker, MetaMask bridge for stamp purchase. Reference architecture: weeb-3. ~3–8 weeks once decided. **Not on the IoT critical path.** |
|  | | |
| **1.0 — full chain integration** | major; deferred | Own Ethereum RPC client + key management + postage contract bindings + on-chain stamp purchase + on-chain cheque cashing. The "approaches Go-bee parity" line. Multi-month project; only do if there's demand from operators who specifically want a non-Go full node. |
|  | | |
| **Future** — pullsync, redistribution game, full storer mode | deferred | Out of scope for the immediate roadmap. |

## 10. What survives from the existing scaffold

| File | Verdict |
|---|---|
| `src/bmt.zig` | Keep — correct against bee golden vectors. |
| `src/crypto.zig` | Keep. |
| `src/identity.zig` | Keep — overlay derivation matches bee; compressed pubkey + DER sign helpers stay. |
| `src/proto.zig` | Keep style; split into `proto.zig` + `multiformats/varint.zig`. |
| `src/noise.zig` | Keep but **fix Phase 0 first**, then reorganise. The two speculative `mixHash` calls must be re-examined under KATs. |
| `src/yamux.zig` | Replace in Phase 1 — current version is header-only, no flow control, no per-stream state. |
| `src/p2p.zig` | Replace in Phase 1 — becomes `libp2p/host.zig`. |
| `src/main.zig` | Replace in Phase 4 with a real CLI. |
| `vendor/secp256k1` | Keep. |

---

*End of plan.*
