# zigbee — operational status snapshot

**Release:** 0.4 — bee-compatible read-only HTTP API ([release notes](RELEASE_NOTES_0.4.md), preceded by [0.3 release notes](RELEASE_NOTES_0.3.md))
**Date:** 2026-04-28
**Tests:** 62/62 unit tests pass (`zig build test --summary all`)
**Source size:** ~7,900 lines of Zig across 27 files in `zigbee/src/`
**Live status against bee:** verified end-to-end against a local bee
(`bee/v2.7.2-rc1`, sepolia testnet config) and against the public
testnet bootnode at `167.235.96.31:32491`.

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
| Local chunk store / reserve | ❌ (we never store) |
| Retrieval *responder* | ❌ (no chunks to serve) |
| Push (uploads) | ❌ (needs postage stamps + chain integration) |
| Pullsync, redistribution | ❌ |
| SOC validation | ❌ (logged, passed through unverified) |
| SWAP cheque payment | ❌ ⇒ caps unpaid retrieval at ~25–30 chunks per peer |
| Mantaray manifest walking (default-document) | ✅ — `/bzz/<manifest-ref>` byte-identical to `bee /bzz/<ref>/` |
| Manifest path lookups (`/bzz/<ref>/<path>` for multi-file) | ⚠️ walker supports it; HTTP route doesn't yet parse the trailing path |
| Encrypted-chunk references | ❌ (refLength=64 not handled) |

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
| `src/identity.zig` | secp256k1 identity, overlay derivation, ECDSA DER + Ethereum-style 65-byte r‖s‖v sign/recover | ✓ KAT + roundtrip |
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
| `src/retrieval.zig` | `/swarm/retrieval/1.4.0/retrieval` initiator; CAC-validated (uses wire-decoded span — fixed bug where intermediate chunks falsely failed validation), SOC pass-through with warning | ✓ + live |
| `src/joiner.zig` | **Chunk-tree reassembler.** Walks span/payload structure: leaf if `span ≤ payload.len`; otherwise payload is concatenated 32-byte child addresses (branching factor 128). Recurses depth-first, concatenates leaf payloads. Sanity-bounds span to 1 TiB to detect SOC-fed-as-CAC | ✓ unit + live (1500 B + 10 000 B byte-identical round-trips) |
| `src/mantaray.zig` | **Mantaray manifest walker.** v0.1/v0.2 binary trie decoder: 64-byte header (32 obfuscation key + 31 version hash + 1 refSize), XOR de-obfuscation, fork iteration with metadata-on-fork JSON decoding. `lookup` matches bee's `LookupNode` semantics (always recurses through forks). `resolveDefaultFile` implements bee's `bzz.go` flow (root `"/"`-fork `website-index-document` metadata → look up that suffix → return entry). Allows `ref_bytes_size = 0` for terminal metadata-only nodes | ✓ unit + live (`/bzz/<manifest-ref>` byte-identical to `bee /bzz/<ref>/`) |
| `src/connection.zig` | Heap-allocated `Connection` owns TCP + NoiseStream + YamuxSession; `dial()` runs the full upstream stack; `startAcceptLoop()` spawns a per-connection accept thread with caller-provided dispatcher; `openStream()` for outbound | live |
| `src/p2p.zig` | The host: dial path, multi-peer connection list, hive-fed auto-dialer with retry-with-backoff and a 15 s manage tick that re-queues unconnected peers, XOR-asc retrieval iteration, **30 s per-attempt watchdog**, HTTP API (`/retrieve`, `/bzz`, `/peers`) | live |
| `src/main.zig` | CLI — `zigbee [resolve|retrieve|daemon]` | — |
| `src/root.zig` | Module entry point | — |

---

## What's NOT in the tree (yet)

These are deliberate gaps, in roughly the order they'd be filled:

- **SWAP cheques (`/swarm/swap/1.0.0/swap`)** — off-chain BZZ payment.
  Without it, bee's per-peer disconnect threshold (~1 350 000 wei,
  ≈ 25–30 chunks at typical proximity-pricing) caps how much we can
  retrieve from a single bee per session. Daemon mode fans out across
  N peers, multiplying the budget by N, but it's still finite. Real
  fix: implement cheque exchange + chequebook contract calls over
  Ethereum RPC.
- **SOC validation.** Single-Owner Chunks pass through unverified; we
  log a CAC mismatch warning. The joiner's span-sanity check (1 TiB
  ceiling) catches the common failure of feeding a SOC reference to
  `/bzz`.
- **Manifests / paths.** `GET /bzz/<ref>/<path>` would walk a manifest
  (mantaray trie) under `<ref>`. Not yet — only raw content addresses.
- **Encrypted-chunk references** (refLength = 64; second 32 bytes are
  the decryption key). Joiner only handles refLength = 32.
- **Pushsync / postage stamps / on-chain integration.**
- **Pullsync, redistribution, status protocol.**
- **Local chunk store** (and the cache layer that goes in front of it).

## Live verification commands

### Daemon against a public testnet bootnode

```bash
cd /home/calin/work/swarm/bee-clients/zigbee
zig build

# Discover entry points (optional — any raw-TCP /ip4/.../tcp/... works):
./zig-out/bin/zigbee resolve sepolia.testnet.ethswarm.org

# Run daemon on a public bootnode; auto-dials up to 4 peers via hive.
./zig-out/bin/zigbee --peer 167.235.96.31:32491 --network-id 10 \
                    daemon --max-peers 4 --api-port 9090 &

# Wait ~15-30s for fan-out, then:
curl -s http://127.0.0.1:9090/peers | jq
# Expect 4 connections + ~10-20 known peers from hive.

curl -s -o chunk.bin "http://127.0.0.1:9090/bzz/<reference>"
```

### End-to-end against a local bee (file upload + retrieval)

```bash
# Start bee; wait for API; buy a small stamp; upload a file.
/tmp/bee start --config testnet.yaml > /tmp/bee.log 2>&1 &
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

Verified live in this session: **1500-byte and 10 000-byte files
round-trip byte-identical**; 700 000-byte file fails mid-walk because
of bee's accounting threshold (Phase 6 SWAP work).

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

---

## Risks / known issues to keep in mind

- **`GeneralPurposeAllocator` deinit is called in `main.zig`**, but
  threads detached from the daemon (per-API-request handlers, watchdog
  threads, dialer worker) outlive the parent function. For a real
  long-running service we'd need a graceful shutdown that joins all
  detached threads.
- **Dead connections aren't pruned.** When bee disconnects us
  (e.g. `disconnect threshold exceeded`), the `Connection` object stays
  in `node.connections`; subsequent retrievals fail fast with
  `BrokenPipe` and iteration moves on, but memory accumulates.
- **Hardcoded threshold-announce of 13 500 000 wei.** That's bee's full-
  node default; a real light node would announce something lower and
  refresh via SWAP cheques. Without SWAP, this number doesn't actually
  buy us anything beyond the per-peer disconnect threshold (~1.35 M).
- **`processHandshakeInitiator` debug prints still in place** (Sent
  Initiator Ephemeral Key, etc.). Task #9 — strip them when we have a
  proper logger module. Useful for development.
- **No graceful shutdown.** `zigbee daemon` runs until killed; the TCP
  RST on exit leaves bee with a "broadcast failed" log. Cosmetic.
- **Yamux session leak risk.** When a connection's accept thread
  exits (e.g. peer reset us), we don't currently remove the
  `Connection` from `node.connections` or call `deinit()` on it.
  Phase 5+ task.
