# zigbee 0.4.1 — release notes

**Date:** 2026-04-28
**Goal:** ship three small quality-of-life wins together as a tag before
starting the longer 0.5 retrieval-maturity work.
**Status:** ✅ all three landed and verified.

## Headline

```bash
$ ./zig-out/bin/zigbee --peer <bee> --network-id 10 daemon &
# First run: writes ~/.zigbee/identity.key (key + bzz nonce, atomic).
# Every subsequent run: same overlay, same secp256k1 key.

$ # Bee disconnects us (accounting kick, TCP RST, peer shutdown)?
$ # The dead Connection gets reaped on the next manage tick:
[prune] reaping dead connection: peer 7179856e…

$ # Retrieving a SOC reference (e.g. a feed) is now signature-validated
$ # rather than passed through unverified — peer can't substitute bytes.
```

## What's new since 0.4

| Patch | Subject | Why it matters |
|---|---|---|
| 0.4.1a | Persistent libp2p identity (`~/.zigbee/identity.key`) | Bee's per-peer accounting state stops resetting on every zigbee restart. Stable overlay across reboots — needed for IoT (a sensor that gets a new overlay each boot is a new peer to bee, with a fresh debt counter). |
| 0.4.1b | Dead-connection pruning on the manage tick | Closes a memory leak: when bee disconnected us (accounting threshold, TCP RST), the `Connection` object stayed in `node.connections` forever. Long-running daemons would slowly accumulate dead structs. |
| 0.4.1c | SOC validation in retrieval | Single-Owner Chunks were previously passed through unverified — any peer serving a SOC reference could substitute arbitrary bytes. Retrieval now validates the SOC signature against the requested address; a mismatch returns `ChunkAddressMismatch`. Required prep for feeds (0.5+). |

## 0.4.1a — persistent libp2p identity

**File format:** 64 bytes — 32-byte secp256k1 private key ‖ 32-byte bzz nonce.
The nonce is part of overlay derivation (`keccak256(eth_addr ‖ network_id_LE ‖ nonce)`)
so it must persist along with the key for the overlay to be stable across runs.

**Atomicity:** write-tempfile-then-rename, so an unclean shutdown either
leaves the previous file fully intact or installs the new one fully —
never produces a partial file. The directory ancestry (`~/.zigbee/`) is
created with default umask; the file is created with no special mode
(use `chmod 0600` post-hoc if your environment requires it; Zig 0.15's
stdlib doesn't expose a portable path-based chmod and `fchmod` panics
on tmpfs so we don't try to set the mode ourselves).

**CLI:**

```
--identity-file <path>      use <path> instead of ~/.zigbee/identity.key
--identity-file :ephemeral: opt out of persistence (regenerate every run)
```

**Verified end-to-end:** 3 launches → same overlay address every time.

## 0.4.1b — dead-connection pruning

**The bug:** when bee's accounting kicked us (we ran past the
~1.35 M wei disconnect threshold) or any TCP-level event closed the
session, our per-connection accept thread would exit cleanly, but the
parent `Connection` struct, its yamux session, noise stream, and TCP
fd all stayed in `P2PNode.connections` indefinitely. Retrievals
against them failed fast with `BrokenPipe` and the origin-retry loop
moved on, so the leak wasn't visible in the API — but every disconnect
cost ~one Connection's worth of heap until process exit.

**The fix:**

- `Connection` grew an `atomic.Value(bool)` flag. The accept loop sets
  it via `defer` whichever way it exits (clean shutdown OR yamux
  session ended).
- `P2PNode.pruneDeadConnections()` walks `connections`, swaps out dead
  entries under the mutex, then `deinit`s them outside the lock
  (`deinit` joins the accept thread — must not happen while holding
  `connections_mtx`).
- The manage tick in the dialer now runs *before* the connectionCount
  gate and calls `pruneDeadConnections()` then
  `requeueUnconnectedPeers()`. The order matters: dead conns inflated
  the count, so without the move the gate kept the dialer asleep and
  the prune never fired.
- `connectionCount` / `closestConnectionTo` /
  `connectionsSortedByDistance` / `handlePeersBee` all filter dead
  conns so callers (dialer, retrieval iteration, `/peers` endpoint)
  don't see ghost peers in the window between accept-loop exit and the
  next manage tick.

**Verified end-to-end:** 50-retrieval hammer triggered bee accounting
kick → `/peers` immediately empty → manage tick fired
`[prune] reaping dead connection` log → dialer auto-reconnected to a
new hive-known peer.

## 0.4.1c — SOC validation in retrieval

**Layout** for a Single-Owner Chunk on the wire (the bytes carried in
retrieval `Delivery.Data`):

```
id(32) ‖ sig(65) ‖ span(8 LE) ‖ payload(≤4096)
```

**Validation:**

```
inner_addr   = bmt(span ‖ payload)                # same hash as CAC
to_sign      = keccak256(id ‖ inner_addr)
eip191_msg   = "\x19Ethereum Signed Message:\n32" ‖ to_sign
signed_digest = keccak256(eip191_msg)
owner        = ecrecover(sig, signed_digest)      # 20-byte eth addr
derived      = keccak256(id ‖ owner)
derived must equal the requested address.
```

**The non-obvious step** is the EIP-191 wrapper. Bee's `crypto.Recover`
applies the prefix transparently in its signing/recovery wrappers, so
even though SOC isn't an Ethereum-message signature in spirit, the
on-the-wire signature is over the EIP-191-prefixed digest. Discovered
by failing against bee's `pkg/soc/soc_test.go` golden vector with the
raw digest; adding the prefix made the recovery match.

**Behaviour change:** the prior "log warning and pass bytes through
unverified" path is gone. Retrieval tries CAC first, then SOC, and
returns `error.ChunkAddressMismatch` if neither validates. Callers
that ignored the warning previously now see a clean failure rather
than potentially bogus bytes.

**`RetrievedChunk` shape:** added optional fields
`is_soc: bool = false`, `soc_id`, `soc_owner`. Existing callers that
didn't read those fields keep working unchanged.

## What zigbee still doesn't do

Unchanged from 0.4 — see [`docs/iot-roadmap.html`](docs/iot-roadmap.html)
and [`docs/strategy.html`](docs/strategy.html). Headline next milestones:

- **0.5.0 — retrieval-maturity** (~10 work-weeks FTE). Local flat-file
  chunk store; encrypted-chunk references (`refLength = 64`); SWAP
  cheques (issue-only, no on-chain cashing) — the headline of 0.5.
- **0.6.0 — push** (~12 weeks FTE). Postage stamps + pushsync +
  `POST /bytes` + `POST /bzz`.
- **0.7.0 — embedded.** ARM Linux release matrix + planned ESP32-S3 spike.

## Numbers

- 8,778 lines of Zig across 28 modules (added `src/soc.zig`).
- **73 / 73** unit tests pass (was 67 in 0.4 — added 5 SOC tests + 1
  raw-digest helper round-trip + 1 EIP-191 helper round-trip).
- Bee golden vector tested: SOC validation against
  `pkg/soc/soc_test.go` (`payload="foo"`, owner `8d3766…e632`).
- 1 vendored C dep (`libsecp256k1`); 0 Go/Rust deps.

## Build

```bash
zig build           # → zig-out/bin/zigbee
zig build test      # → 73/73
```

Requires Zig 0.15.x and a C toolchain.
