# zigbee 0.1 — release notes

**Date:** 2026-04-28
**Goal:** retrieve a chunk from the live Swarm network in pure Zig.
**Status:** ✅ achieved end-to-end.

## Headline

```
$ zigbee retrieve 27f82a81b11f830204e256fc9af30c2a46e044bfed22c5f2a9952c3fef0e4da3 -o chunk.bin
[bee-hs-out] handshake done: peer overlay=…046c9a network=10 full_node=true
[bee-hs-out] welcome: "your welcome meessage"
[pricing-out] announced our payment threshold to peer
[retrieve] requesting chunk 27f82a81…
[retrieve] got 2656 bytes (span=…, stamp=0 bytes)
[retrieve] wrote 2656 bytes to chunk.bin

$ cmp <(curl -s http://127.0.0.1:1633/chunks/27f82a81… | tail -c +9) chunk.bin
IDENTICAL
```

zigbee retrieves a chunk over the Swarm network and gets back the same
bytes bee's REST API returns. Pure Zig + a single vendored C dep
(libsecp256k1).

## Numbers

- **6,202** lines of Zig in **24** modules in `src/`.
- **53** unit tests, **53** passing (`zig build test`).
- **1** vendored C dependency: `libsecp256k1` (≈ 60 kB compiled, used
  for ECDSA recoverable signatures).
- **~18 MB** Debug binary, smaller in Release.
- **0** Go or Rust dependencies. No FFI to other libp2p stacks.

## What's in 0.1

zigbee implements every protocol on the boundary between us and bee:

- **Network**: TCP, libp2p Noise XX (`/noise`), Yamux v0
  (`/yamux/1.0.0`) negotiated via NoiseExtensions.
- **libp2p identity**: multistream-select 1.0.0,
  Identify (`/ipfs/id/1.0.0`), Ping (`/ipfs/ping/1.0.0`).
- **Swarm application**: bee handshake (`/swarm/handshake/14.0.0`),
  pricing (`/swarm/pricing/1.0.0`, both directions), hive peer-discovery
  (`/swarm/hive/1.1.0`), retrieval (`/swarm/retrieval/1.4.0`).
- **DNS bootstrap**: RFC 1035 DNS-over-UDP TXT lookup with recursive
  `/dnsaddr/` resolution.

Plus the supporting layers: BMT chunk addressing, Ethereum-style
secp256k1 sign/recover with EIP-191 prefixing, libp2p PeerID multihash,
multiaddr text↔binary, hand-rolled protobuf primitives, ChaCha20-Poly1305
+ X25519 + Keccak (Zig std), ECDSA-P256 verifier (Zig std — bee's
libp2p identity is P-256, not secp256k1).

bee log confirms zigbee is recognised as a real Swarm peer:

```
"msg"="handshake finished for peer (inbound)" "peer_address"="<our overlay>"
"msg"="greeting message from peer" "message"="zigbee says hello"
"msg"="stream handler: successfully connected to peer (inbound)"
       "addresses"="[Overlay: <ours>, Underlays: [/ip4/0.0.0.0/tcp/0/p2p/<our PeerID>]]"
       "light"=" (light)"
```

`curl http://127.0.0.1:1633/peers` returns 17 testnet bees + zigbee = 18.

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
```

Example: connect directly to a testnet bootnode (no local bee
required) and stay connected so you can watch the hive broadcasts:

```
$ zigbee --peer 167.235.96.31:32491 --network-id 10
[bee-hs-out] handshake done: peer overlay=3ef22bdd… network=10 full_node=true
[bee-hs-out] welcome: "Welcome to the Testnet!"
[hive] broadcast: 7 added, 0 rejected, table size 7
```

Full usage in [`README.md`](README.md).

## Build

```bash
zig build           # → zig-out/bin/zigbee
zig build test      # → 53/53
```

Requires Zig 0.15.x and a C toolchain (for the vendored libsecp256k1).

## What's NOT in 0.1

These are deliberate omissions, scoped out so 0.1 could ship. They
are listed in priority order for Phase 5+:

- **No push** (`/swarm/pushsync/1.3.1`). Requires postage stamps,
  which require chain integration.
- **No multi-chunk file reassembly.** Files larger than ~4 KB in
  Swarm are stored as a chunk tree; 0.1 retrieves only single
  chunks. The 4096-byte ones work; larger files round-trip the
  root chunk only.
- **No SOC validation.** Single-Owner Chunks are returned but not
  cryptographically verified — we log a CAC mismatch and pass the
  bytes through.
- **No closest-peer routing.** We have a peer table from hive,
  but retrieval always asks bee directly.
- **Single-peer dial.** One peer per run, via `--peer ip:port`. We
  don't yet keep multiple simultaneous connections.
- **Bootnodes are flaky retrieval peers.** `--peer <bootnode>` works
  for connection (handshake, hive, identify) but bootnodes are
  forwarders, not stores: retrieval against them often
  `error.StreamReset`s. For reliable retrieval, dial a non-bootnode
  bee that has the chunk in (or near) its neighborhood.
- **No daemon mode.** zigbee runs one operation and exits.
- **No on-chain interaction.** No JSON-RPC client, no postage
  stamps, no chequebook, no SWAP settlement.

See [`PLAN.md`](PLAN.md) for the planned phases.

## Notable findings during 0.1 development

These cost real time to figure out and are worth remembering. The full
session log is in commit history; here are the highlights:

1. **libp2p `KeyType` enum is 2=Secp256k1 / 3=ECDSA, not the reverse.**
   We had it inverted, which made bee reject our libp2p identity as
   "InvalidPublicKey" the first day.

2. **Bee's libp2p identity is ECDSA-P256, not secp256k1.** This was
   surprising — bee is an Ethereum-flavoured project, but its libp2p
   key uses a different curve from its blockchain key. Bee separates
   them. Required adding a P-256 SubjectPublicKeyInfo parser
   (`src/libp2p_key.zig`) and a Zig-std `EcdsaP256Sha256` verifier.

3. **Bee negotiates the stream multiplexer in Noise extensions, not in
   inner multistream-select.** We initially tried the standard libp2p
   inner multistream-select for Yamux and bee just reset us. Looking
   at `go-libp2p`'s upgrader: if the Noise security handshake's
   `NoiseExtensions { stream_muxers: [...] }` has overlap, the muxer
   is committed during Noise; otherwise fall back to multistream.
   We had to add NoiseExtensions to our msg3 payload.

4. **Bee's BzzAddress signature in hive broadcasts is NOT verifiable
   end-to-end.** Bee strips/filters underlays after signing, so the
   wire signature only matches the original underlays (which bee no
   longer ships). Bee's own receiver doesn't verify hive entries —
   they're advisory peer hints, verified only on direct handshake.
   We added `bzz_address.parseNoVerify` for this case.

5. **Bee's per-protocol ConnectIn loop is synchronous and serial.**
   Pricing's `init` calls `stream.FullClose()`, which waits for our
   FIN. If we don't close our end, bee's ConnectIn loop blocks ~30 s
   on the close timeout, delaying the `pseudosettle.init` that flips
   `accountingPeer.connected = true`. Without `connected = true`,
   bee's retrieval handler returns "connection not initialized yet".
   The fix was a one-line `s.close()` after our pricing/hive
   responders return — saved 30 s of latency and unblocked retrieval.

6. **Bee's per-stream Headers exchange is asymmetric.** Initiator
   writes headers first, responder reads first. We had a single
   `exchangeEmptyHeaders` that did read-then-write (responder-style)
   and used it from both sides; bee's retrieval handler timed out on
   "read headers" because we were also waiting to read. Two
   variants now: `exchangeEmptyHeaders` (responder) and
   `exchangeEmptyHeadersInitiator`.

7. **Bee's accounting requires a minimum payment threshold of
   `2 × refreshRate = 9_000_000`.** This is bee's own minimum
   regardless of whether the peer is light or full. zigbee announces
   `13_500_000` (matches bee's full-node default).

## Tests

```
$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 53/53 tests passed
```

KAT and golden-vector tests:
- `noise_kat`: Cacophony XX vector + flynn/noise oracle.
- `bmt`: bee chunk-address golden vectors (`foo`, `greaterthanspan`).
- `identity`: bee overlay-derivation golden vectors.
- `bzz_address`: signed-overlay round-trip + rejection of mismatched
  overlay.
- `peer_table`: proximity-order computation, closest-peer XOR
  distance, upsert idempotency, self-overlay drop.

## Files

```
zigbee/
├── build.zig
├── build.zig.zon
├── README.md                     # user-facing usage doc
├── RELEASE_NOTES_0.1.md          # this file
├── src/                          # 24 .zig files, 6202 lines
└── vendor/secp256k1/             # vendored libsecp256k1
```

Plus operational docs alongside the README:

```
zigbee/
├── PLAN.md                       # multi-phase roadmap
└── STATUS.md                     # rolling operational snapshot
```

## Acknowledgements

zigbee borrows protocol details from `bee/v2.7.x` (Apache-2.0 / BSD-3-Clause)
and uses test vectors from cacophony (BSD-3-Clause) and flynn/noise (MIT).
