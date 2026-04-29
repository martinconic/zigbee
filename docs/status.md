# zigbee — operational status snapshot

**Release:** 0.5.1 (tagged) — adds `--bootnode` flag (`/dnsaddr/<host>` or `/ip4/.../tcp/...`, mirrors bee's `testnet.yaml`). Built on 0.5.0's retrieval-maturity: local chunk store + encrypted-chunk refs + SWAP cheques (issue-only), live-verified end-to-end against bee on Sepolia. ([0.5.1 release notes](release-notes/0.5.1.md), preceded by [0.5.0](release-notes/0.5.0.md), [0.4.2](release-notes/0.4.2.md), [0.4.1](release-notes/0.4.1.md), [0.4](release-notes/0.4.md))
**Next on `main` (0.6.0 milestone):** push — postage stamp parser + verifier + issuer + `/swarm/pushsync/1.3.1` initiator + `POST /bytes` and `POST /bzz` upload API. ~12 work-weeks FTE. Per-target chain integration stays an outer ring (operator-side provisioning), not zigbee core.
**Headline focus:** **IoT / embedded.** zigbee is the small-footprint Bee client family for devices that can't run Go bee. Locked in 2026-04-28; framing detail in [`iot-roadmap.html`](iot-roadmap.html).
**Strategy references:** [`iot-roadmap.html`](iot-roadmap.html) (IoT-specific roadmap) + [`strategy.html`](strategy.html) (full strategic dossier)
**Date last refreshed:** 2026-04-29
**Tests:** 113/113 unit tests pass (`zig build test --summary all`)
**Source size:** ~11,500 lines of Zig across 34 files in `zigbee/src/` (added in 0.5.0: `src/store.zig`, `src/encryption.zig`, `src/cheque.zig`, `src/swap.zig`, `src/accounting.zig`, `src/credential.zig`)
**Repository:** https://github.com/martinconic/zigbee (public, BSD-3-Clause)
**Live status against bee:** verified end-to-end against a local bee
(`bee/v2.7.2-rc1`, sepolia testnet config) and against the public
testnet bootnode at `167.235.96.31:32491`. SWAP cheques live-verified
2026-04-29 against a deployed Sepolia chequebook
(`0xcc853f656ede26b73a9d9e2e710f6c506e12d6fa`): 25/25 retrievals,
8 cheques accepted, zero threshold disconnects.

---

## ⚓ Resumption checkpoint

Single-page guide for picking the project up cold. If a session crashes,
your machine reboots, or you come back in a week — read this section
first.

### Where everything lives

| Thing | Path / URL |
|---|---|
| **Repo (local)** | `/home/calin/work/swarm/bee-clients/zigbee` |
| **Repo (GitHub)** | https://github.com/martinconic/zigbee |
| **Default branch** | `main` (in sync with `origin/main`) |
| **Latest tag** | `v0.5.1` (0.6.0 push milestone is the next concrete work on `main`) |
| **Bee source we cross-reference** | `/home/calin/work/swarm/dev/bee` (Go) |
| **Spec PDFs** | `/home/calin/work/swarm/bee-clients/docs/{swarm_protocol_spec.pdf, the-book-of-swarm-2.pdf}` |
| **Local bee binary** | `/home/calin/work/swarm/bee-clients/bee/bee-bin` (built locally with `go build -o ./bee-bin ./cmd/bee/` inside the `bee/` repo; ~70 MB; gitignored). Testnet config: `/home/calin/work/swarm/bee-clients/testnet.yaml`. |
| **Test stamp batch** | Buy a fresh one each session — older batches expire / get cleaned up. `curl -X POST http://127.0.0.1:1633/stamps/100000000/17` then poll `/stamps/<id>` until `usable: true` (~2 min on Sepolia). |

### Smoke test in one command (verifies everything still works)

```bash
cd /home/calin/work/swarm/bee-clients/zigbee
zig build test --summary all   # expect: 113/113 tests passed
```

### What's done (per-release)

- **0.1** — single-chunk retrieval over forwarding-Kademlia. CLI:
  `zigbee retrieve <hex> -o file`. ([0.1 release notes](release-notes/0.1.md))
- **0.3** — daemon mode, multi-peer connection management with retry/
  backoff and a manage tick, spec §1.5 origin retry, 30 s per-attempt
  timeout, chunk-tree joiner for multi-chunk files, mantaray manifest
  walker for `/bzz/<ref>` (default-document resolution).
  ([0.3 release notes](release-notes/0.3.md))
- **0.4** — bee-compatible read-only HTTP API: `/health`,
  `/readiness`, `/node` (`beeMode: ultra-light`), `/addresses`,
  `/peers`, `/topology`, `/chunks/<addr>`, `/bytes/<ref>`,
  `/bzz/<ref>`, `/bzz/<ref>/<path>` — drop-in for bee's read-only
  REST surface, byte-identical responses on the storage endpoints.
  ([0.4 release notes](release-notes/0.4.md))
- **0.4.1** — three small operability/correctness wins shipped
  together: (a) persistent libp2p identity + bzz nonce in
  `~/.zigbee/identity.key` (atomic-write), (b) dead-connection
  pruning on the manage tick (closes a slow memory leak), (c) SOC
  validation in retrieval (was: pass-through unverified; now
  signature-validated with bee-golden-vector test, returns
  `ChunkAddressMismatch` on neither-CAC-nor-SOC).
  ([0.4.1 release notes](release-notes/0.4.1.md))
- **0.4.2** — clears the three smaller pending items left over
  after 0.4.1: (a) strip 10 noisy `std.debug.print` lines from the
  Noise XX hot path in `noise.zig` (per-attempt `[dialer]` /
  `[retrieve]` logs are kept), (b) `POST /pingpong/<peer-overlay>`
  HTTP endpoint — bee shape, returns `{"rtt":"<duration>"}` with
  Go-style duration formatting, (c) graceful shutdown on
  SIGINT/SIGTERM — module-level atomic flag + poll-gated
  `serveApi` loop + dialer-thread join, so bee no longer logs
  "broadcast failed" when we exit.
  ([0.4.2 release notes](release-notes/0.4.2.md))
- **0.5.1** *(tagged 2026-04-29)* — **`--bootnode` flag.** Accepts
  `/dnsaddr/<host>` or `/ip4/.../tcp/.../p2p/...` multiaddrs, mirrors
  bee's `testnet.yaml` `bootnode:` field. zigbee resolves DNS internally,
  walks candidates in order on initial dial, falls through on failure.
  `--peer` keeps its precise meaning (dial *this exact peer*) and is
  mutually exclusive with `--bootnode`. 6 new unit tests; total 113/113.
  Also shipped: `examples/install-kit/` — generalised onboarding scripts
  paired with `docs/install.html`. See
  [`release-notes/0.5.1.md`](release-notes/0.5.1.md).
- **0.5.0** *(tagged 2026-04-29)* — **retrieval-maturity.** Three
  sub-items shipped together; full prose in
  [`release-notes/0.5.0.md`](release-notes/0.5.0.md):
  - **0.5a** local flat-file chunk store with basic LRU. `src/store.zig`,
    atomic write, hashmap + DLL LRU under one mutex, startup scan
    rebuilds the index. CLI: `--store-path` / `--store-max-bytes`
    (default 100 MiB) / `--no-store`. 6 unit tests.
  - **0.5b** encrypted-chunk references (`refLength = 64`). New
    `src/encryption.zig` implements bee's keccak256-CTR segment
    cipher; `joiner.zig` gained `joinEncrypted` (branching factor
    64); `/bytes/`, `/bzz/`, `/retrieve/` detect 128-char hex prefixes.
    Live-verified against bee on Sepolia: 105 ms cold / 11 ms cached.
  - **0.5c** SWAP cheques (issue-only, no on-chain cashing). EIP-712
    signing in `src/cheque.zig` — byte-identical to bee's
    `TestSignChequeIntegration` golden vector. Stream protocol in
    `src/swap.zig` (`/swarm/swap/1.0.0/swap` initiator). Per-peer
    accounting in `src/accounting.zig`; cumulative-payout state lives
    next to the chequebook credential at `<chequebook>.state.json`
    (B2 — wiping `~/.zigbee/store/` no longer corrupts cheque
    monotonicity). Cheque amount is computed at emit time from the
    negotiated exchange_rate (`delta_wei = exchange_rate ×
    CREDIT_TARGET_BASE_UNITS + deduction`) so cheques scale correctly
    with whatever rate the peer announces. CLI: `--chequebook PATH`.
    **Live-verified 2026-04-29:** deployed chequebook
    `0xcc853f656ede26b73a9d9e2e710f6c506e12d6fa` on Sepolia,
    25/25 retrievals, 8 cheques accepted, zero threshold disconnects.

### What's open / pending (development plan locked in 2026-04-28)

The strategic conversation following the 0.4 release ended with an
agreed four-milestone roadmap. Captured in detail at
[`strategy.html`](strategy.html) (single self-contained HTML page,
opens in any browser); the per-task list lives in
[`plan.md`](plan.md) §9.

**0.5.0 retrieval-maturity is shipped (2026-04-29).** The next concrete
step is **0.6.0 — push** (~12 weeks FTE):

4. Postage stamp parser + verifier + issuer + bucket-index tracking.
5. `/swarm/pushsync/1.3.1` initiator + receipt verification.
6. HTTP `POST /bytes`, `POST /bzz` upload API (with manifest building).

**Then 0.7.0 — embedded** (IoT headline; ~5 weeks ARM + ~4 weeks MCU):

7. ARM Linux release matrix (cross-compile libsecp256k1 for armv7
   + arm64; validate on Pi Zero; GitHub Actions release artifacts).
8. ESP32-S3 spike — *planned* (re-classed from "gated" 2026-04-28
   when IoT was locked in as the headline focus).

**Then 0.8+ — in-browser** *(deferred decision; revisit after 0.7)*:

9. wasm32-freestanding via WebSocket; secp256k1 strategy decided
   (likely JS FFI to `noble-secp256k1` for v1); MetaMask bridge for
   stamp purchase. Reference architecture: weeb-3.

**Then 1.0 — full chain integration** *(major; defer until demand)*:

10. Own Ethereum RPC client + key management + on-chain stamp
    purchase + on-chain cheque cashing. The "approaches Go-bee
    parity" line.

### Smaller pending items not on the milestone path

Nothing outstanding here right now — the next concrete work is
0.6.0 push above. Cross-cutting items that the IoT roadmap calls
out (resource bounds, persistent state already done, CI cross-
compile, production logging, ReleaseSmall validation) are paired
with the milestone they unlock.

### Conventions / preferences observed in this project

- License: **BSD-3-Clause** (matches bee). Vendored libsecp256k1 is MIT.
- Vendor strategy: `vendor/secp256k1/` is the upstream tree with `.git`
  stripped, pinned to commit `ea174fe045e1832548cd3b7090958afe9573ad2b`
  of `bitcoin-core/secp256k1`. Provenance in `vendor/README.md`.
- Recommended production build: **`zig build -Doptimize=ReleaseSafe`**
  (~6 MB, safety checks on). `ReleaseSmall` (~1.4 MB) is flagged for
  the upcoming embedded + in-browser work.
- Docs are split: `README.md` at root (overview + TL;DR), and under
  `docs/`: `usage.md` (cookbook), `architecture.md` (model + threading +
  accounting wall), `plan.md` (multi-phase roadmap), `status.md` (this
  file — operational snapshot, the most-likely-to-be-stale),
  `install.html` (noob-friendly first-run guide paired with
  `examples/install-kit/`), and `release-notes/0.X.md` per release.
- Commit style: subject + body explaining the *why*, not just the
  *what*.

> zigbee dials any TCP-reachable bee → completes Noise XX → opens Yamux →
> serves libp2p Identify, Ping → completes the bee `/swarm/handshake/14.0.0`
> application handshake → exchanges `/swarm/pricing/1.0.0` and
> `/swarm/hive/1.1.0/peers` → in **daemon** mode auto-dials hive-discovered
> peers up to `--max-peers` → serves an HTTP API on 127.0.0.1:9090 with
> `GET /retrieve/<hex>` for single chunks and `GET /bzz/<ref>` for full
> files via chunk-tree (joiner) reassembly. Forwarding-Kademlia retrieval
> is performed by the bee peers we dial; zigbee is the *origin* and the
> *reassembler*.

---

## Architecture summary

Zigbee is an **ultra-light Swarm client** — even lighter than bee's `light: true` mode.

| Concern | Zigbee |
|---|---|
| Runs full libp2p+Swarm stack against bee | ✅ |
| Discovers peers via `/swarm/hive/1.1.0/peers` | ✅ |
| Maintains multiple direct peer connections | ✅ (auto-dialer + manage tick) |
| Retrieves chunks (single + chunk-tree files) | ✅ via spec §1.5 origin-retry + bee's forwarding-Kademlia |
| Validates content-addressed chunks (CAC) | ✅ BMT + span |
| Local chunk store (read cache) | ✅ added in 0.5a — flat-file LRU at `~/.zigbee/store/`, default 100 MiB, atomic write |
| Retrieval *responder* | ❌ (no chunks to serve) |
| Push (uploads) | ❌ (needs postage stamps + chain integration) |
| Pullsync, redistribution | ❌ |
| SOC validation | ✅ (added in 0.4.1c — keccak256(id ‖ owner) verified, mismatch returns ChunkAddressMismatch) |
| SWAP cheque payment | ✅ added in 0.5c, live-verified 2026-04-29 against a deployed Sepolia chequebook — EIP-712-signed cheques on `/swarm/swap/1.0.0/swap`, byte-identical to bee's `TestSignChequeIntegration` golden vector. Cheque amount sized at emit-time from the negotiated `exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction`. State (last cumulative_payout per peer) lives at `<chequebook>.state.json`, paired with the credential. Issue-only (cashing on-chain is 1.0). |
| Mantaray manifest walking (default-document) | ✅ — `/bzz/<manifest-ref>` byte-identical to `bee /bzz/<ref>/` |
| Manifest path lookups (`/bzz/<ref>/<path>` for multi-file) | ✅ — HTTP route parses trailing path, walker does the lookup, byte-identical to `bee /bzz/<ref>/<path>` (added in 0.4) |
| Bee-compatible read-only HTTP API (`/health`, `/node`, `/addresses`, `/peers`, `/topology`, `/chunks`, `/bytes`) | ✅ added in 0.4 — drop-in for bee tools |
| `POST /pingpong/<peer-overlay>` (bee `pkg/api/pingpong.go`) | ✅ added in 0.4.2 — opens a stream, runs `/ipfs/ping/1.0.0`, returns `{"rtt":"<duration>"}` Go-style |
| Graceful shutdown on SIGINT/SIGTERM | ✅ added in 0.4.2 — atomic flag + poll-gated `serveApi` + dialer-thread join → bee no longer logs "broadcast failed" |
| Encrypted-chunk references | ✅ added in 0.5b — joiner+mantaray walk 64-byte refs, `decryptChunk` (keccak256-CTR) restores plaintext; both `/bytes/<128-hex>` and `/bzz/<128-hex>/...` work transparently |

In bee's terms zigbee is closer to *no-storer client* than *light node*;
bee logs us with `light=" (light)"` once handshake reports `full_node = false`.

The intentional model: **zigbee never decides which bee in the network has
the data, never routes a chunk through itself, never does a Kademlia
lookup.** It's the requester at one end and the file-reassembler when a
multi-chunk reference is fetched. The forwarding-Kademlia walk that
eventually reaches a chunk's neighbourhood happens entirely inside the
bee peers zigbee is connected to.

---

## What's in the tree

| File | Purpose | Tested |
|---|---|---|
| `src/crypto.zig` | Keccak256 helper | ✓ |
| `src/bmt.zig` | BMT chunk hashing — 128-segment Binary Merkle Tree, matches bee golden vectors | ✓ KAT |
| `src/identity.zig` | secp256k1 identity, overlay derivation, ECDSA DER + Ethereum-style 65-byte r‖s‖v sign/recover; **persistent identity (`loadOrCreate` writes 32-byte key + 32-byte bzz nonce to `~/.zigbee/identity.key` atomically)**; `recoverEthAddrFromDigest` (raw) + `recoverEthAddrEip191` helpers used by SOC validation | ✓ KAT + roundtrip |
| `src/proto.zig` | Hand-rolled protobuf primitives (varint, NoiseHandshakePayload, NoiseExtensions, libp2p PublicKey) | ✓ |
| `src/multiaddr.zig` | `/ip4/`, `/tcp/`, `/dns*/`, `/p2p/`; text↔binary; helpers for ip4Tcp/dnsHost/peerIdBytes | ✓ |
| `src/multistream.zig` | libp2p multistream-select 1.0.0 client + server | ✓ |
| `src/noise.zig` | Noise XX initiator + responder; carries peer libp2p key out via NoiseStream | ✓ KAT + oracle + localhost roundtrip |
| `src/noise_kat.zig` | Cacophony XX vector + flynn/noise libp2p oracle | ✓ |
| `src/libp2p_key.zig` | libp2p PublicKey enum dispatch (Secp256k1 = 2, ECDSA = 3) + P-256 SubjectPublicKeyInfo parser + verifier | ✓ |
| `src/peer_id.zig` | libp2p PeerID multihash (identity for ≤42-byte keys, sha2-256 otherwise); helpers to build `/ip4/.../tcp/.../p2p/<id>` | ✓ |
| `src/yamux.zig` | Real Yamux session: per-stream state, condvar-based blocking I/O, reader thread, accept/open, ACK/FIN/RST/Ping/WindowUpdate, **`Stream.cancel()`** for retrieval-timeout watchdog | ✓ headers + live wire |
| `src/identify.zig` | `/ipfs/id/1.0.0` responder + initiator | ✓ + live |
| `src/ping.zig` | `/ipfs/ping/1.0.0` 32-byte echo, both sides | ✓ live |
| `src/dnsaddr.zig` | RFC 1035 DNS-over-UDP TXT lookup with recursive `/dnsaddr/` resolution | ✓ + live |
| `src/swarm_proto.zig` | Shared bee-stream framing: `readDelimited`, `writeDelimited`, `exchangeEmptyHeaders`, `exchangeEmptyHeadersInitiator` | — |
| `src/bee_handshake.zig` | `/swarm/handshake/14.0.0/handshake` — Syn/SynAck/Ack protobuf, BzzAddress signing (EIP-191 + Keccak + secp256k1), responder + initiator | ✓ KAT + live |
| `src/bzz_address.zig` | BzzAddress decode + signature verification + `UnderlayIterator` for bee's 0x99-prefixed multi-underlay list | ✓ KAT |
| `src/peer_table.zig` | HashMap by overlay + 32 Kademlia bins indexed by leading-bit proximity; `closestTo(addr)` for routing | ✓ |
| `src/pricing.zig` | `/swarm/pricing/1.0.0/pricing` responder + initiator (announce our threshold) | live |
| `src/hive.zig` | `/swarm/hive/1.1.0/peers` responder; populates `peer_table` with advisory entries (bee strips/filters underlays after signing → wire signature is non-verifiable end-to-end; bee itself doesn't verify hive entries either) | live |
| `src/retrieval.zig` | `/swarm/retrieval/1.4.0/retrieval` initiator; tries CAC first (BMT with wire-decoded span) then SOC validation (added 0.4.1c); returns `ChunkAddressMismatch` if neither validates rather than the prior pass-through-unverified | ✓ + live |
| `src/soc.zig` | **Single-Owner Chunk parser + validator** (added 0.4.1c). Layout `id(32) ‖ sig(65) ‖ span(8) ‖ payload`; validates `keccak256(id ‖ recovered_owner) == requested_addr`, where the signature is recovered over the EIP-191-prefixed `keccak256(id ‖ inner_cac_addr)` (mirrors bee's `crypto.Recover`). | ✓ bee golden vector |
| `src/joiner.zig` | **Chunk-tree reassembler.** Walks span/payload structure: leaf if `span ≤ payload.len`; otherwise payload is concatenated 32-byte child addresses (branching factor 128). Recurses depth-first, concatenates leaf payloads. Sanity-bounds span to 1 TiB to detect SOC-fed-as-CAC | ✓ unit + live (1500 B + 10 000 B byte-identical round-trips) |
| `src/mantaray.zig` | **Mantaray manifest walker.** v0.1/v0.2 binary trie decoder: 64-byte header (32 obfuscation key + 31 version hash + 1 refSize), XOR de-obfuscation, fork iteration with metadata-on-fork JSON decoding. `lookup` matches bee's `LookupNode` semantics (always recurses through forks). `resolveDefaultFile` implements bee's `bzz.go` flow (root `"/"`-fork `website-index-document` metadata → look up that suffix → return entry). Allows `ref_bytes_size = 0` for terminal metadata-only nodes | ✓ unit + live (`/bzz/<manifest-ref>` byte-identical to `bee /bzz/<ref>/`) |
| `src/connection.zig` | Heap-allocated `Connection` owns TCP + NoiseStream + YamuxSession; `dial()` runs the full upstream stack; `startAcceptLoop()` spawns a per-connection accept thread with caller-provided dispatcher; `openStream()` for outbound; **`dead: atomic.Value(bool)` set when the accept loop exits (any reason)** — feeds the manage-tick reaper | live |
| `src/p2p.zig` | The host: dial path, multi-peer connection list, hive-fed auto-dialer with retry-with-backoff and a 15 s manage tick that **prunes dead connections** then re-queues unconnected peers, XOR-asc retrieval iteration (skips dead conns), **30 s per-attempt watchdog**, HTTP API (`/retrieve`, `/bzz`, `/peers`) | live |
| `src/main.zig` | CLI — `zigbee [resolve|retrieve|daemon]`; **0.5a:** `--store-path`, `--store-max-bytes`, `--no-store` | — |
| `src/p2p.zig` (0.4.2 additions) | `POST /pingpong/<overlay>` route + `formatGoDuration` helper + `g_shutdown` atomic + SIGINT/SIGTERM handler + poll-gated `serveApi` + joinable dialer thread | ✓ unit (`formatGoDuration` golden samples) |
| `src/store.zig` (0.5a) | Local flat-file chunk store with basic LRU. `<root>/<2-hex>/<64-hex>` layout, atomic write (tempfile + fsync + rename), hashmap + DLL index under one mutex, startup scan rebuilds index from file mtimes. `Store.openOrCreate` / `get` / `put` / `deinit`. | ✓ 6 unit tests (round-trip, miss, eviction, MRU-on-hit, restart-resume, shrunken-cap) |
| `src/encryption.zig` (0.5b) | Bee-compatible keccak256-CTR segment cipher for encrypted refs. `transform(key, buf, init_ctr)` (involutive: encrypt = decrypt), `decryptChunk(allocator, key, encrypted_chunk)` returns owned `decrypted_span(8) ‖ trimmed-payload`, `encryptedRefCount(span)` for intermediate-chunk ref counts (branching=64). Span uses `init_ctr=128`, data uses `init_ctr=0` — disjoint keystreams. | ✓ 5 unit tests (bee golden vector for 4 KiB zeros, involutive, span/data disjoint, leaf round-trip, ref-count) |
| `src/cheque.zig` (0.5c) | SWAP cheque data model + EIP-712 typed-data signing. `Cheque{chequebook,beneficiary,cumulative_payout}`, `SignedCheque{cheque,signature}`, `domainSeparator(chain_id)`, `structHash(*Cheque)`, `signingDigest(*Cheque, chain_id)`, `sign` (recoverable secp256k1 with v∈{27,28}), `recoverIssuer`, `marshalJson`/`unmarshalJson` (Go-default `encoding/json` shape — capitalised fields, address `0x..`, payout JSON number, signature base64). | ✓ bee golden vector (`TestSignChequeIntegration`: priv `634fb5a8…`, payout 500, chainId 1, signature `171b63fc…2fc421c`) + recover round-trip + JSON round-trip + u256 decimal helpers |
| `src/swap.zig` (0.5c) | `/swarm/swap/1.0.0/swap` initiator. `SettlementHeaders{exchange_rate,deduction}` (BE uint256), `parseSettlementHeaders` (tolerates field order; missing-deduction → 0; missing-exchange errors), `negotiate(stream)` (write empty out → read bee's), `sendCheque(stream, *SignedCheque)` (`EmitCheque{Cheque: <json>}` protobuf). No inbound responder — retrieval-only clients never receive cheques. | ✓ headers round-trip with both fields, missing-field defaults, EmitCheque tag/length wrapping |
| `src/accounting.zig` (0.5c) | Per-peer SWAP accounting state + persistence. `Accounting.openOrCreate(allocator, ?state_path)`, `charge(peer, n_chunks)` (returns true at trigger), `buildCheque(peer, contract, beneficiary, delta_wei)` (caller computes delta from negotiated headers; persists new cumulative atomically *before* returning), `markChequeSent`, `snapshot`, `seedCumulative(peer, value)` for wrapper-driven recovery, `deriveStatePath(chequebook_path)`. State lives in one JSON document at `<chequebook>.state.json` (B2 — paired with the credential, not a separate `accounting/` tree); peer-overlay → cumulative-decimal. `TRIGGER_CHUNKS = 3`; `CREDIT_TARGET_BASE_UNITS = 10 M` (≈7× bee's announced threshold). Ephemeral mode (no path) when zigbee runs without `--chequebook`. | ✓ 7 unit tests (charge below trigger, trigger + cumulative monotonic, state survives reopen, per-peer isolation, ephemeral mode, seedCumulative + idempotence, deriveStatePath) |
| `src/credential.zig` (0.5c) | Chequebook credential loader. `ChequebookCredential{contract,owner_private_key,chain_id}`, `load(allocator, path)`. Tolerates `0x`-prefixed and raw hex. Returns typed errors (`InvalidContract`, `InvalidPrivateKey`, `InvalidChainId`, `InvalidCredentialFile`) for malformed fields. | ✓ 3 unit tests (valid file, missing field, malformed hex) |
| `src/root.zig` | Module entry point | — |

---

## What's NOT in the tree (yet)

These are deliberate gaps, in roughly the order they'd be filled:

- **Pushsync (`/swarm/pushsync/1.3.1`) + postage stamps.** No upload
  path. The whole 0.6.0 milestone — postage stamp parser + verifier
  + issuer + bucket-index tracking, then pushsync initiator + receipt
  verification, then `POST /bytes` and `POST /bzz` upload routes.
- **Cashing received cheques on-chain.** zigbee never *receives*
  cheques (retrieval-only client; bee never owes us BZZ), so this
  is a non-issue today. When push lands and bee owes us, we'd need
  an inbound swap handler + `Chequebook.cashCheque` on Ethereum RPC
  — both deferred to 1.0 along with the rest of full chain integration.
- **Pullsync, redistribution, status protocol.** Full-node-only
  protocols; not on the IoT roadmap.

## Live verification commands

### Daemon against a public testnet bootnode

```bash
cd /home/calin/work/swarm/bee-clients/zigbee
zig build

# Discover entry points (optional — any raw-TCP /ip4/.../tcp/... works):
./zig-out/bin/zigbee resolve sepolia.testnet.ethswarm.org

# Run daemon on a public bootnode (0.5.1 — `--bootnode` resolves
# /dnsaddr/ via DNS-TXT, walks candidates in order, falls through on
# dial failure). Auto-dials up to 4 peers via hive.
./zig-out/bin/zigbee --bootnode /dnsaddr/sepolia.testnet.ethswarm.org \
                    --network-id 10 \
                    daemon --max-peers 4 --api-port 9090 &

# Wait ~15-30s for fan-out, then:
curl -s http://127.0.0.1:9090/peers | jq
# Expect 4 connections + ~10-20 known peers from hive.

curl -s -o chunk.bin "http://127.0.0.1:9090/bzz/<reference>"
```

### End-to-end against a local bee (file upload + retrieval)

```bash
# Build (once) + start bee. Wait for API + readiness, buy a small stamp, upload a file.
cd /home/calin/work/swarm/bee-clients/bee && go build -o ./bee-bin ./cmd/bee/ && cd ..
./bee/bee-bin start --config testnet.yaml > /tmp/bee.log 2>&1 &
until curl -sf http://127.0.0.1:1633/health >/dev/null; do sleep 1; done
BATCH=$(curl -s -X POST http://127.0.0.1:1633/stamps/100000000/17 | jq -r .batchID)
# Wait ~2 minutes for stamp to confirm on-chain.
until curl -sf http://127.0.0.1:1633/stamps/$BATCH | jq -e '.usable' >/dev/null; do sleep 5; done
REF=$(curl -s -X POST -H "Swarm-Postage-Batch-Id: $BATCH" \
            --data-binary "@./my-file.bin" \
            "http://127.0.0.1:1633/bytes" | jq -r .reference)

# Now retrieve via zigbee.
./zig-out/bin/zigbee --peer 127.0.0.1:1634 --network-id 10 \
                    daemon --max-peers 1 --api-port 9090 &
sleep 12
curl -s -o /tmp/from-zigbee.bin "http://127.0.0.1:9090/bzz/$REF"
cmp ./my-file.bin /tmp/from-zigbee.bin && echo "BYTE-IDENTICAL"
```

Verified live: small + multi-chunk + encrypted files all round-trip
byte-identical against bee on Sepolia. With 0.5c shipped, large files
no longer fail at bee's disconnect threshold — zigbee issues SWAP
cheques on `/swarm/swap/1.0.0/swap` before the threshold trips.
Reproduce with `bee-clients/scripts/{01,02,03,06,12}-*.sh` (see
that directory's README for the runbook).

---

## Recently fixed bugs (worth remembering)

| Bug | Symptom | Fix |
|---|---|---|
| BMT was flat keccak | `Chunk Hash: …` disagreed with bee | 128-segment Binary Merkle Tree, validated against bee golden vectors |
| Overlay was `keccak(pubkey)` | Bee rejected our handshake | `keccak256(eth_addr ‖ networkID_LE_u64 ‖ nonce_32)` |
| libp2p `KeyType` enum reversed | Couldn't decrypt bee's NoiseHandshakePayload | 2 = Secp256k1, 3 = ECDSA (it was the other way) |
| Bee uses ECDSA-P256, not secp256k1, for libp2p identity | Signature verification failed | Added P-256 SubjectPublicKeyInfo parser; use `std.crypto.sign.ecdsa.EcdsaP256Sha256` |
| Yamux read length only correct for Data frames | Random crashes mid-handshake | Switch on frame_type when interpreting `length` field |
| Bee skips inner multistream-select for muxer | Hung after Noise | `NoiseExtensions { muxers = ["/yamux/1.0.0"] }` carries muxer choice during XX |
| Bee's per-stream Headers exchange (asymmetric) | Bee read-blocked, never sent Delivery | `exchangeEmptyHeadersInitiator` writes first, reads back |
| `connection not initialized yet` on retrieval | Pricing announce lost a race with bee's `ConnectIn` | 2 s post-handshake delay before announcing threshold; also `s.close()` on inbound stream handlers so bee's `pricing.init` `FullClose` doesn't block ~30 s |
| Bee disconnects with `disconnect threshold exceeded` after our threshold announce | Pricing minimum is 2*refreshRate = 9 M | Send 13 500 000 (bee's full-node default) |
| One-shot dial sometimes only got 1 peer | Hive broadcasts vary; failed dials weren't retried | Per-peer attempt count + exponential backoff (15/30/60/120 s) + manage tick every 15 s requeues unconnected peers |
| `/retrieve` returned 502 the first time, sometimes worked the next time | Single-peer retrieval; spec §1.5 says origin should retry next candidate on Err | Iterate `connectionsSortedByDistance` on `error.PeerError` / `error.StreamReset` / 30 s timeout |
| Hung peer would block retrieval forever | No per-attempt timeout | Watchdog thread per attempt using `Condition.timedWait` + `Stream.cancel()` (RST + signal waiters); 30 s matches bee's `RetrieveChunkTimeout` |
| `/bzz` returned `error.OutOfMemory` on SOC references | Joiner read first 8 bytes of SOC identifier as span — produced 9.3 quintillion → ensureCapacity OOM | Added `MAX_REASONABLE_SPAN = 1 TiB` ceiling + `LikelySocReference` error |
| Every intermediate chunk falsely failed CAC validation | `bmt.Chunk.init(payload)` defaulted span to `payload.len`; for intermediate chunks the real span is the total subtree size | Use the wire-decoded span explicitly when computing the BMT address |
| `/bzz` on `bee POST /bzz`-uploaded references returned the manifest's binary bytes | No manifest walker | Added `src/mantaray.zig`, auto-detect mantaray header on root chunk, walk the trie |
| Mantaray walker first-pass: returned the fork's `ref` (sub-manifest chunk address) instead of the child node's `entry` (file ref) | Walker stopped at remaining=="" | Always recurse into the fork's child after a prefix match — match bee's `LookupNode` |
| Mantaray parser rejected `ref_bytes_size = 0` | `Error.UnsupportedRefSize` on terminal manifest nodes | Allow 0; skip forks at `ref_size=0` (matches bee's `UnmarshalBinary` v0.2) |
| Overlay regenerated on every restart, breaking bee accounting state | Persistent identity (0.4.1a) saved only the secp256k1 key — overlay also depends on `nonce`, which was still randomized in `P2PNode.init` | File format extended to 64 bytes (key ‖ nonce); `loadOrCreate` returns both; `P2PNode.init` accepts nonce as a parameter |
| Dead `Connection`s accumulated forever after bee disconnected us | Accept thread exited but `node.connections` was never pruned (0.4.1b) | Add `Connection.dead` atomic, set via `defer` on accept-loop exit; `pruneDeadConnections()` called by manage tick (which had to be moved before the connectionCount gate, otherwise dead conns kept the dialer asleep) |
| SOC validation matched against the raw `keccak256(id ‖ inner_addr)` digest and recovery returned the wrong owner (0.4.1c) | Bee's `crypto.Recover` applies EIP-191 prefix internally, even though SOC isn't an Ethereum-message signature in spirit | Sign/recover over `keccak256("\x19Ethereum Signed Message:\n32" ‖ to_sign)` instead; bee's `pkg/soc/soc_test.go` golden vector now passes |
| Daemon flooded stderr with 10 Noise-XX prints per peer (0.4.2a) | `processHandshakeInitiator` / `processHandshakeResponder` had `std.debug.print` calls left over from initial debugging | Stripped all 10; per-attempt `[dialer]` / `[retrieve]` logs in `p2p.zig` are kept (still useful for development) |
| `daemon` had no clean-exit path (0.4.2c) | Process killed → kernel TCP RST → bee logged "broadcast failed" | Module-level `g_shutdown: std.atomic.Value(bool)` + SIGINT/SIGTERM `sigaction` handler + `std.posix.poll(.., 200ms)`-gated `serveApi` accept loop + dialer-thread join — bee sees a clean FIN |
| Pingpong endpoint missing (0.4.2b) | Bee tools polling `POST /pingpong/<addr>` got 404 | Route added; reuses the existing `ping.ping` client + a Go-style `formatGoDuration` helper |

---

## Risks / known issues to keep in mind

- **Hardcoded threshold-announce of 13 500 000 wei.** That's bee's full-
  node default; a real light node would announce something lower and
  refresh via SWAP cheques. With SWAP shipped (0.5c), the threshold
  number announced *to* bee is mostly cosmetic — bee's threshold *for*
  us (1.35 M base units in the live test) is what governs disconnect,
  and zigbee now clears that with a cheque every 3 retrievals.
- **Detached per-request API handler threads not joined on shutdown.**
  0.4.2c joins the dialer thread cleanly and the listener stops
  accepting, but in-flight `/bzz` retrievals running on detached
  handler threads finish on their own (≤30 s thanks to the watchdog).
  Process exit reaps them. Acceptable for now; promote to a real fix
  when graceful shutdown is itself stress-tested under heavy
  concurrent retrieval load.
- **No proactive Yamux GoAway frame on shutdown.** We close the TCP
  socket directly via `Connection.deinit`; bee sees an orderly EOF
  and ends the session normally — that's enough to suppress
  "broadcast failed". A real GoAway is a ≤10-line follow-up if a
  future peer needs it.
