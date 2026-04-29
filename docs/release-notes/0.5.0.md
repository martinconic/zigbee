# zigbee 0.5.0 — release notes

**Status:** the headline of 0.5.0 is **retrieval-maturity**: local
chunk store, encrypted-chunk references, and SWAP cheques (issue-only).
All three sub-items have landed and SWAP is live-verified end-to-end
against bee on Sepolia (see 0.5c-e below).

| Sub-item | State |
|---|---|
| 0.5a — local flat-file chunk store with basic LRU | ✅ landed |
| 0.5b — encrypted-chunk references (`refLength = 64`) | ✅ landed |
| 0.5c — SWAP cheques (issue-only, no on-chain cashing) | ✅ landed (live-verified end-to-end on Sepolia 2026-04-29) |

---

## 0.5a — local flat-file chunk store with basic LRU

**Why it matters:** before 0.5a every retrieval hit the network and
counted against bee's per-peer accounting threshold (~1.35 M wei,
≈ 25–30 chunks). With a local cache, repeated reads of a recently-
fetched chunk are zero-cost. For IoT this is the first piece of
real persistence — a sensor that reboots no longer re-pays for the
firmware blob it pulled an hour ago.

### What's new

```bash
$ zigbee daemon --max-peers 4 &
[store] root=/home/me/.zigbee/store max_bytes=104857600
[daemon] dialing bootnode 167.235.96.31:32491 (network_id=10)
...

# First retrieval — network fetch + cache write-back.
$ time curl -so /tmp/x.bin http://127.0.0.1:9090/bzz/<ref>
real    0m0.412s

# Second retrieval — cache hit, no network round-trip.
$ time curl -so /tmp/x.bin http://127.0.0.1:9090/bzz/<ref>
real    0m0.003s
```

### New module — `src/store.zig` (~470 lines incl. tests)

| API | Purpose |
|---|---|
| `Store.openOrCreate(allocator, root, max_bytes) !*Store` | Creates/opens the store dir; scans existing files; rebuilds the LRU index by mtime descending; evicts down to `max_bytes` if shrunk. |
| `Store.get(addr) !?StoredChunk` | O(1) hashmap lookup; on hit, moves the entry to MRU and reads the file. Race-safe against concurrent eviction (returns null if the file vanished between index lookup and open). |
| `Store.put(addr, span, data) !void` | Atomic write (tempfile → fsync → rename). Updates index; evicts oldest until under cap. Replacing an existing addr correctly adjusts byte counter. |
| `Store.deinit()` | Frees every Entry + the hashmap + root path. |
| `defaultStorePath(allocator)` | Returns `$HOME/.zigbee/store`. Caller owns. |

### Layout on disk

```
~/.zigbee/store/
├── ab/
│   └── ab12...ef34       # span(8 LE) ‖ payload (≤ 4 KiB)
├── cd/
│   └── cd56...7890
└── ...
```

The 2-hex prefix sharding bounds any single dir to ≤ 256 files for
the first 65 536 cached chunks (saves ext4 dir-lookup time on
bigger caches; ext4's htree handles much more but it's cheap
defence-in-depth on slower filesystems / SD cards / SquashFS overlays).

### Concurrency

- One mutex (`Store.mtx`) around the in-memory index — the doubly-
  linked LRU + the address→entry hashmap.
- File reads/writes happen **outside** the lock, so multiple
  retrieval threads can pull cached chunks in parallel; the only
  contention is the index update on hit (touch) or miss-then-insert.
- Filesystem ops are atomic: tempfile + `f.sync()` + rename mirrors
  the pattern proven in `identity.zig:writeKeyAndNonceAtomic`.

### Wire-up in `src/p2p.zig`

`P2PNode.retrieveChunkIterating` now goes:

1. **Cache lookup.** If `node.store != null`, ask the store. On hit,
   wrap the bytes in a `RetrievedChunk` (transferring ownership) and
   return — no `connectionsSortedByDistance`, no per-attempt
   timeout, no SWAP cost.
2. **Network fetch.** Existing forwarding-Kademlia origin-retry loop.
3. **Cache write-back.** On a successful network fetch, `store.put`
   is called best-effort. A failure (full disk, permission denied,
   …) is logged but never fails the retrieval that already
   succeeded — the bytes are returned to the caller regardless.

`P2PNode.init` grew a `store: ?*Store` parameter; `P2PNode.deinit`
calls `store.deinit()` if non-null.

### CLI flags

```
--store-path P      path to the local chunk-store directory
                    (default $HOME/.zigbee/store/).
--store-max-bytes N cap the local store at N bytes (default 100 MiB).
--no-store          disable the local chunk store entirely.
```

The 100 MiB default fits a Pi Zero comfortably (≈ 25 000 chunks at
4 KiB each); the cross-cutting X1 item in `docs/iot-roadmap.html` §4
will tune defaults per-target as the embedded work in 0.7 lands.

### What's intentionally NOT here (deferred)

- **No content re-validation on read.** Retrieval already validated
  CAC/SOC before insert; trusting our own writes is fine. (If a
  later version of the format adds an integrity-MAC, retrofit it
  here.)
- **No background flush queue.** fsync per put is fine at retrieval
  rates (one chunk per network round-trip ≫ one fsync; bee's
  accounting threshold caps churn well under what synchronous fsync
  can sustain).
- **No staging-store abstraction.** That's 0.6 push work — a
  separate "to-be-uploaded" set lives alongside the cache, not
  inside it.
- **No persistent LRU ordering.** Restart re-seeds the LRU from
  file mtimes; close enough to the live ordering that a long
  uptime followed by a restart loses at most a handful of would-be-
  cached entries on the first eviction round.

### Tests

6 new unit tests in `src/store.zig`, all using `std.testing.tmpDir`
so each test gets its own scratch directory:

- `round-trip put/get a single chunk`
- `miss on unknown address returns null`
- `over-cap eviction removes oldest`
- `get bumps entry to MRU so it survives next eviction`
- `restart-resume re-loads existing chunks`
- `shrunken cap on reopen evicts down-to`

Total suite: **80 / 80** unit tests pass.

### Numbers

- ~470 new lines in `src/store.zig` (350 implementation + 120 tests).
- ~50 changed lines in `src/p2p.zig` (cache-first lookup + write-back).
- ~30 new lines in `src/main.zig` (three CLI flags + store
  open-before-init).
- ReleaseSafe build: 6.6 MB (was 6.3 MB; +300 KB from the new module
  and `std.fs` / `std.DoublyLinkedList` pulls).

### Build

```bash
zig build           # → zig-out/bin/zigbee, debug
zig build test      # → 80/80
zig build -Doptimize=ReleaseSafe   # → ~6.6 MB
```

Requires Zig 0.15.x and a C toolchain.

---

## 0.5b — encrypted-chunk references (`refLength = 64`)

**Why it matters:** bee uploads with `Swarm-Encrypt: true` produce
a 128-char hex reference (32-byte address ‖ 32-byte symmetric key).
Each chunk in the tree is encrypted with a key derived from its
parent reference, and the tree's branching factor changes from 128
(unencrypted) to 64 (each child slot now holds addr+key, not just
addr). Without 0.5b a zigbee daemon couldn't read anything pinned
encrypted — i.e. anything where the publisher cared about
confidentiality on the wire / on the storers' disks. With 0.5b in,
the daemon transparently retrieves both forms.

### What's new

```bash
# Upload encrypted via bee (returns 128-char ref).
$ REF=$(curl -sS -X POST -H "Swarm-Postage-Batch-Id: $BATCH" \
        -H "Swarm-Encrypt: true" \
        --data-binary @file.bin http://127.0.0.1:1633/bytes \
        | jq -r .reference)
$ echo $REF | wc -c
129    # 128 hex + newline

# Retrieve transparently — zigbee detects 128-char refs and decrypts.
$ time curl -so out.bin http://127.0.0.1:9090/bytes/$REF
real    0m0.105s
$ cmp file.bin out.bin && echo OK
OK

# CLI form works too — single-chunk leaves only.
$ zigbee --peer 127.0.0.1:1634 retrieve $REF -o out.bin
[retrieve] requesting chunk da63...4876 (encrypted) via peer 7179...6c9a
[retrieve] got 4096 bytes (span=10027656661073034444)
[retrieve] wrote 2048 bytes to out.bin
```

### New module — `src/encryption.zig` (~330 lines incl. tests)

Bee's chunk cipher is keccak256-CTR, segment-keyed:

```
seg_key[i] = keccak256(keccak256(key ‖ u32_LE(i + init_ctr)))
out[i*32 .. (i+1)*32] = in[i*32 .. (i+1)*32] XOR seg_key[i]
```

Two `init_ctr` regimes share one 32-byte key per chunk:
- **data**: `init_ctr = 0`, covers 4096 B of payload (128 segments)
- **span**: `init_ctr = 128 (= CHUNK_SIZE / SEGMENT_LEN)`, covers the
  8-byte length prefix — picked so its keystream never overlaps the data's

| API | Purpose |
|---|---|
| `transform(key, buf, init_ctr)` | XOR `buf` in place with the segment-keyed keystream. Involutive, so encrypt = decrypt. |
| `decryptChunk(allocator, key, encrypted_chunk) ![]u8` | Decrypts a wire-form chunk (`span(8)‖payload`); returns owned `decrypted_span(8) ‖ trimmed-payload`. Trims to the real span on leaves; trims to the encrypted-tree branching count on intermediates. |
| `encryptedRefCount(span) usize` | Given a decrypted span, return how many 64-byte child refs the intermediate chunk holds (branching factor 64, capacity grows by powers of 64). |

Golden vector: 4 KiB of zeros, key `[1; 32]`, `init_ctr=0` produces
the exact byte sequence the bee Go reference does (verified
segment-by-segment in `test "encryption: matches bee golden vector"`).

### Joiner — `src/joiner.zig`

Added `joinEncrypted(allocator, ctx, fetch, root_addr, root_key)`
alongside the unencrypted `join`. Both share an internal `walk`
that takes an `is_encrypted: bool`:

- Unencrypted: `ref_len = 32`, parse children as bare addresses.
- Encrypted: `ref_len = 64`, split each ref into 32 B addr + 32 B
  key, fetch the child, **decrypt with that key**, recurse.

The decrypt happens on every chunk in the tree — root, intermediates,
leaves — using the key that came in *with the ref pointing at it*.
This is bee's design for forward-secrecy: knowing one subtree's key
gives you that subtree but never its sibling.

### Mantaray — `src/mantaray.zig`

The on-the-wire mantaray format already encodes its own
`refBytesSize` byte (32 vs 64), so the parser was ref-size agnostic
out of the box. The change in 0.5b is one comment update plus the
loader contract: when the manifest itself is reached via an
encrypted ref, the loader callback gets the *decrypted* chunk
bytes, and a fork ref of length 64 means the *child* chunk is also
encrypted. zigbee's `mantarayLoaderAdapter` (in `src/p2p.zig`)
peels off the 32-byte key suffix when present and decrypts before
parsing the child.

### HTTP routing — `src/p2p.zig`

```zig
pub const Ref = struct {
    addr: [bmt.HASH_SIZE]u8,
    key: ?[encryption.KEY_LEN]u8 = null,
};
```

`/bytes/<hex>`, `/bzz/<hex>/...`, `/retrieve/<hex>` all parse 64-
or 128-char hex into a `Ref`. `joinByRef` dispatches to `join` or
`joinEncrypted`. `handleBzzApi` decrypts the root chunk before
checking `mantaray.looksLikeManifest`, so a 128-char ref pointing
at an encrypted manifest works transparently.

### CLI

`retrieve` accepts either 64 chars (unencrypted CAC) or 128 chars
(encrypted ref); `runRetrievalAgainst` decrypts the leaf when the
key is present. Help text updated.

### Tests

5 new unit tests in `src/encryption.zig` + 2 in `src/joiner.zig`:

- `encryption: transform matches bee golden vector (4 KiB zeros)`
- `encryption: transform is involutive (encrypt then decrypt)`
- `encryption: data init_ctr=0 and span init_ctr=128 keystreams disjoint`
- `encryption: decryptChunk leaf round-trip`
- `encryption: encryptedRefCount across span ranges`
- `joiner: encrypted single-leaf round-trip`
- `joiner: encrypted two-leaf intermediate round-trip`

Total suite: **87 / 87** unit tests pass.

### Live verification

`/home/calin/work/swarm/bee-clients/scripts/04-upload-encrypted-file.sh`
+ `11-verify-zigbee-encrypted-refs.sh` against the Go bee reference
on Sepolia testnet:

| Path | Cold | Cached | Notes |
|---|---|---|---|
| `/bytes/<128-hex>` (single-chunk, 2 KiB) | 105 ms | 11 ms | byte-identical |
| `/bytes/<128-hex>` (multi-chunk, 16 KiB) | 858 ms | n/a | byte-identical, 1 root + 4 leaves |
| `/bzz/<128-hex>/` (encrypted manifest, 2 KiB) | 1.12 s | n/a | byte-identical, manifest+leaves all decrypted |
| CLI `retrieve <128-hex> -o file` | 1× chunk | n/a | byte-identical for single-chunk leaves |

Clean shutdown after SIGINT, zero "broadcast failed" lines on bee
(0.4.2c regression baseline holds).

### What's intentionally NOT here (deferred)

- **CLI multi-chunk encrypted retrieval.** `retrieve <128-hex>`
  fetches one chunk; for files >4 KiB you need the daemon's
  `/bytes/` route which goes through `joinEncrypted`. The CLI
  is a debug primitive, not a file-download tool.
- **Encrypted /bytes upload from zigbee.** 0.6 push-side work.
- **Re-encrypting on cache write.** We cache the *encrypted* leaf
  chunk on disk (same bytes bee returned), and decrypt on read.
  This is intentional: storing decrypted plaintext would defeat
  the upload encryption, and the keccak256-CTR cost on a cache hit
  is ~8 µs per 32-byte segment — negligible vs. disk I/O.

## 0.5c — SWAP cheques (issue-only, no on-chain cashing)

**Why it matters.** Bee announces a per-peer payment threshold
(~13.5M wei for full nodes) at handshake time. Without SWAP, every
chunk we retrieve increments bee's view of our debt; once debt >
threshold, bee disconnects us with `apply debit: disconnect threshold
exceeded` — capping retrieval at ~25–30 chunks per peer per session.
With SWAP we issue an EIP-712-signed cheque before reaching that wall;
bee credits us, debt resets in bee's view, retrieval continues.
Multi-peer fan-out (`--max-peers 4+`) extended the budget linearly;
SWAP removes the wall outright (subject to chequebook funding).

The 0.5c headline is *issue-only, no on-chain cashing*: zigbee signs +
emits cheques. Cashing received cheques on-chain — calling
`Chequebook.cashCheque(...)` — stays deferred to 1.0. Consistent with
the strategy doc's per-target outer-ring model: zigbee's core never
talks to the chain; chain interactions live in the outer ring (browser:
wallet, server: own RPC, embedded: pre-flashed credential).

### What's new

```bash
$ cat ~/chequebook.json
{
  "contract":          "0xfa02D396842E6e1D319E8E3D4D870338F791AA25",
  "owner_private_key": "0x634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd",
  "chain_id":          11155111
}

$ zigbee --peer 127.0.0.1:1634 --network-id 10 \
         --chequebook ~/chequebook.json \
         daemon --max-peers 4
[swap] loading chequebook credential from /home/me/chequebook.json
[swap] chequebook contract=0xfa02d396842e6e1d319e8e3d4d870338f791aa25 chain_id=11155111
...
# After ~20 retrievals from any one peer, the swap path fires:
[swap] 7179856e…: negotiated exchange=10000 deduction=0;
       emitting cheque cumulativePayout=10800000
[swap] 7179856e…: cheque accepted by stream layer; chunk counter reset
```

Without `--chequebook`, accounting still tracks per-peer debt — adding
the credential later is a one-line toggle, not a state-rebuild — but
no cheques are issued. Pre-0.5c behaviour preserved.

### New module — `src/cheque.zig` (~425 lines incl. tests)

Cheque data model + EIP-712 typed-data signing.

| API | Purpose |
|---|---|
| `Cheque{chequebook,beneficiary,cumulative_payout}` | The unsigned promise. |
| `SignedCheque{cheque,signature}` | Cheque + 65-byte r‖s‖v signature. |
| `domainSeparator(chain_id) → [32]u8` | EIP-712 domain hash for `Chequebook` v1.0 on the given chain. |
| `structHash(*Cheque) → [32]u8` | Per-cheque struct hash. |
| `signingDigest(*Cheque, chain_id) → [32]u8` | `keccak256("\x19\x01" ‖ domain ‖ struct)`. |
| `sign(*Cheque, chain_id, owner_priv) → [65]u8` | Recoverable secp256k1 over the digest; v ∈ {27, 28}. |
| `recoverIssuer(*SignedCheque, chain_id) → [20]u8` | Pull the chequebook owner's eth address out of a signed cheque (what bee does on receive). |
| `marshalJson` / `unmarshalJson` | Wire format — Go-default `encoding/json` shape (capital-cased fields, address as `0x..`, `cumulativePayout` as JSON number, signature as base64). |

Verified byte-identical to ganache's signature against bee's
`TestSignChequeIntegration` golden vector (priv `634fb5a8…`, chequebook
`0xfa02…`, beneficiary `0x98E6…`, payout 500, chainId 1 → signature
`171b63fc598ae2c7…2fc421c`). EIP-712 hashing was the highest-risk
piece (must byte-match go-ethereum's `apitypes` exactly); the golden
vector confirms the typeHashes, address padding, BE encoding, and
`\x19\x01` prefix are all correct.

### New module — `src/swap.zig` (~315 lines incl. tests)

`/swarm/swap/1.0.0/swap` initiator (issue-only — we never receive).

| API | Purpose |
|---|---|
| `PROTOCOL_ID` | `/swarm/swap/1.0.0/swap`. |
| `SettlementHeaders{exchange_rate, deduction}` | Big-endian uint256 fields bee fills from its priceoracle. |
| `parseSettlementHeaders(buf) !SettlementHeaders` | Decode bee's response Headers protobuf. Tolerates fields in any order; missing `deduction` → 0; missing `exchange` is an error. |
| `negotiate(stream) !SettlementHeaders` | Initiator: write empty outbound headers, read + parse bee's. |
| `sendCheque(stream, *SignedCheque)` | Build `EmitCheque{Cheque: <json>}` protobuf, varint-length-prefix, write to stream. |

We don't register an inbound handler. Retrieval-only clients never
receive cheques (bee never owes us BZZ); if bee ever opens a swap
stream against us, the dispatcher falls through to "unknown protocol"
and the stream resets. Bee logs and moves on.

### New module — `src/accounting.zig` (~470 lines incl. tests)

Per-peer SWAP accounting state + persistence.

| API | Purpose |
|---|---|
| `Accounting.openOrCreate(allocator, root)` | Open `~/.zigbee/accounting/`; rescan + rebuild index from per-peer state files. |
| `charge(peer, n_chunks) !bool` | Increment counter; returns true if `≥ TRIGGER_CHUNKS` (default 20). |
| `buildCheque(peer, contract, beneficiary) !Cheque` | Compute `last_cumulative + CHEQUE_AMOUNT_WEI`; **persist atomically before returning** so a crash mid-send won't issue a stale cumulative on retry. |
| `markChequeSent(peer)` | Reset chunk counter to 0. |
| `snapshot(peer) ?PeerStateSnapshot` | Read-only state inspection (used by tests + future `/accounting` endpoint). |

State files: `~/.zigbee/accounting/<peer-overlay-hex>.json`. One per
peer. Atomic write — same `tempfile + fsync + rename` pattern as
`src/identity.zig` and `src/store.zig`. Files smaller than 200 bytes;
parse errors at scan time are logged and skipped without blocking
startup.

Defaults: `TRIGGER_CHUNKS = 20` (slightly below bee's ~25–30 disconnect
window for headroom on the cheque round-trip), `CHEQUE_AMOUNT_WEI =
10_800_000` (~80% of bee's announced 13.5M threshold). Both `pub const`
so they're easy to retune later.

### New module — `src/credential.zig` (~155 lines incl. tests)

Chequebook credential loader.

```json
{
  "contract":          "0x...",
  "owner_private_key": "0x...",
  "chain_id":          <int>
}
```

Tolerates `0x`-prefixed and raw hex. Returns typed errors (`InvalidContract`,
`InvalidPrivateKey`, `InvalidChainId`, `InvalidCredentialFile`) for any
malformed field. Contents are not validated against an actual deployed
contract — that's bee's job at receive time, via
`factory.VerifyChequebook` against the canonical Swarm chequebook factory.

### Wire-up — `src/p2p.zig`

`P2PNode` grew two fields: `accounting: ?*Accounting` and
`chequebook: ?ChequebookCredential`. After every successful
*network* retrieval (cache hits short-circuit before the SWAP hook):

1. `accounting.charge(peer_overlay, 1)` — always called when accounting
   is set, regardless of chequebook.
2. If charge returns true AND chequebook is set:
   * `accounting.buildCheque(peer, contract, peer_eth_addr)` →
     persists the new cumulative atomically and returns the unsigned
     cheque.
   * `cheque.sign(...)` → 65-byte recoverable signature.
   * Open a fresh stream on the same connection, multistream-select
     `/swarm/swap/1.0.0/swap`, `swap.negotiate(...)`, `swap.sendCheque(...)`.
   * `accounting.markChequeSent(peer)` → reset counter.
3. Any failure (no connected peers, swap rejected, network drop) is
   logged + dropped. Counter stays elevated; the next retrieval that
   re-trips the threshold retries.

### CLI flag

```
--chequebook P      path to a chequebook credential JSON file:
                    {{ "contract": "0x..", "owner_private_key":
                    "0x..", "chain_id": <int> }}. When set,
                    zigbee signs SWAP cheques and emits them
                    to peers we owe BZZ to (~every 20 chunks).
                    Without it, accounting still tracks debt
                    but never issues — bee's per-peer
                    disconnect threshold (~25–30 chunks) stays
                    the ceiling.
```

### Tests

11 new unit tests across the four new modules:

- `cheque`: bee golden vector signature match (the integration test);
  recoverIssuer round-trip; marshalJson/unmarshalJson round-trip; u256
  decimal helper round-trip; signingDigest depends on chainId.
- `swap`: parseSettlementHeaders with both fields; missing-deduction
  defaults to 0; missing-exchange errors; buildEmitChequePb wraps json
  correctly; bytesToU256BE round-trip.
- `accounting`: charge below trigger; trigger at 20; cumulative
  monotonic across cheques; state survives reopen; per-peer isolation.
- `credential`: load valid file; missing-field rejected; malformed-hex
  rejected.

Total suite: **104 / 104** unit tests pass.

### 0.5c-e — live verification against a deployed chequebook (2026-04-29)

The wire protocol was already byte-identical to bee's golden vector
in 0.5c-rc1, but rc1 left bee's on-chain solvency check unproven —
bee's `chequestore.ReceiveCheque` requires the chequebook contract
to exist *and* hold enough sBZZ to cover `cumulative_payout`.

For 0.5.0 final we wired the operator-side provisioning path and
ran the full loop on Sepolia:

1. **Deployed a chequebook** via the canonical Sepolia factory at
   `0x0fF044F6bB4F684a5A149B46D7eC03ea659F98A1`. The factory's
   `deploySimpleSwap(issuer, hardDepositTimeout=0, nonce=<random>)`
   emits `SimpleSwapDeployed(address)`; the operator script
   (`scripts/06-deploy-zigbee-chequebook.sh`) parses that log to
   get the contract address. zigbee's eth address (derived from the
   first 32 bytes of `~/.zigbee/identity.key`) is the issuer, so the
   same key signs cheques *and* owns the chequebook — `ecrecover`
   on a received cheque returns the chequebook's `issuer()`,
   bee accepts.
2. **Funded with 1 BZZ** by ERC20-transferring sBZZ
   (`0x543dDb01Ba47acB11de34891cD86B675F04840db`) directly to the
   chequebook contract. No `approve` + `transferFrom` dance needed
   since we don't use the chequebook's `Deposit()` method.
3. **Hammered bee with 25× single-chunk retrievals** on
   `--max-peers 1` against a fresh `~/.zigbee/accounting/`. With
   `--no-store` to defeat the cache short-circuit, each retrieval
   hits the network → trips accounting → eventually triggers a
   cheque on the swap stream.
4. **Result:** 25/25 retrievals succeeded, **8 cheques accepted by
   bee** (cumulativePayout 1e14 → 8e14 wei), zero
   `disconnect threshold exceeded` lines for our overlay. Confirmed
   via bee's `GET /chequebook/cheque` API:
   ```
   "peer": "e94b5c8e…",
   "lastreceived": {
     "beneficiary": "0x56250Aef…",
     "chequebook":  "0xCC853F656EdE26b73A9d9e2e710f6C506e12D6FA",
     "payout":      "800000000000000"
   }
   ```
   Bee verified the EIP-712 signature, ran `factory.VerifyChequebook`
   against the on-chain contract, passed the bouncing-cheque check,
   and credited us. End-to-end SWAP works.

### Dynamic cheque sizing — the rc1 → final fix

rc1 hardcoded `CHEQUE_AMOUNT_WEI = 20 M wei`. That's wrong: bee's
accounting (payment_threshold, per-chunk debit) is denominated in
**base units**, not wei, with the conversion
`credited_base_units = (cumulative_payout - deduction) / exchange_rate`
applied bee-side using *bee's* announced exchange_rate. With
exchange_rate = 100 k, a 20 M wei cheque credited only 199 base
units against a 1.35 M base-unit threshold — bee silently accepted
but the credit was negligible, and the next few retrievals tipped
us back over the disconnect threshold.

For 0.5.0 final, `chargeAndMaybeIssue` now negotiates the swap
headers *first*, then computes
`delta_wei = exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction`
where `CREDIT_TARGET_BASE_UNITS = 10 M` (≈7× bee's announced
threshold, comfortable headroom regardless of what rate the peer
quotes). The persistence-before-send invariant still holds: build
+ persist happen after negotiate but before sign+send, so a crash
mid-send re-issues the same cumulative on retry rather than
diverging.

### Cumulative-payout state lives with the chequebook (B2)

A second issue surfaced during verification: `last_cumulative_payout_wei`
was stored at `~/.zigbee/accounting/<peer-overlay>.json`, completely
detached from `~/.zigbee/chequebook.json`. That's a data-model bug.
cumulativePayout is logically per-(chequebook, peer) — it means
"*this* chequebook owes *this* peer this much." Storing it elsewhere
makes the invariant violatable by accident: wipe `accounting/`
(operator confused, partial restore, fresh-install over an existing
chequebook) and the next cheque undershoots bee's stored value, bee
rejects with `cheque cumulativePayout is not increasing`, threshold
disconnect.

For 0.5.0 final, the state file moved next to the chequebook
credential: `chequebook.json` → `chequebook.state.json`, single
JSON document with all peers' cumulatives:

```json
{ "version": 1,
  "peers": {
    "<peer-overlay-hex>": "<cumulative-decimal>"
  } }
```

The directory `~/.zigbee/accounting/` no longer exists in 0.5.0+.
With this layout, the operator backup/restore unit becomes
`identity.key + chequebook.json + chequebook.state.json` — three
files, all in `~/.zigbee/`, naturally co-located. Wiping any one
without the others is the operator's call.

For partial-state recovery (`chequebook.state.json` lost but
chequebook still bound to bee), zigbee exposes
`Accounting.seedCumulative(peer, value)` — a wrapper or operator
script can query bee's `GET /chequebook/cheque` for the
authoritative stored cumulative and seed our local view to match.
The bundled `12-verify-zigbee-swap.sh` script demonstrates this
seeding pattern; it's what a production wrapper would do during
disaster recovery.

### What's intentionally NOT here (deferred)

- **Receive-side cheque handling.** Retrieval-only clients never
  receive cheques. If we ever push (0.6+) and bee owes us BZZ, we'd
  need an inbound swap handler. Stub for that lives in 1.0.
- **Cashing received cheques on-chain.** `Chequebook.cashCheque(...)`
  is a chain transaction, deferred to 1.0 per the strategy doc.
- **Priceoracle / pricing-handshake threshold parsing.** zigbee
  reads bee's `payment_threshold` announcement byte-count but
  doesn't yet capture the value into per-connection state. Cheque
  sizing instead targets a constant (`CREDIT_TARGET_BASE_UNITS`)
  that comfortably exceeds any plausible threshold. Refining to
  threshold-aware sizing is a 0.5.x or 0.6.x ergonomics improvement,
  not a correctness gap.
- **Multi-peer SWAP under load.** Per-peer state lives in a single
  `chequebook.state.json` keyed by peer overlay (independent
  cumulative tracking). Live-tested only with `--max-peers 1`. Same
  code paths exercised under multi-peer; no per-peer races we can
  identify.
- **Auto-bootstrap from bee on partial-state restore.** Today the
  operator/wrapper queries bee's `GET /chequebook/cheque` and calls
  `seedCumulative` (or writes the state file directly, as the
  test script does). A future ergonomics improvement could plumb
  this into zigbee's startup path so it self-heals with no wrapper
  involvement; intentionally deferred — bee's HTTP isn't always
  reachable at recovery time, and operator-driven restore is more
  reliable than client-side auto-recovery.
- **Cumulative-payout overflow handling.** A u256 will not realistically
  overflow at any plausible delta_wei rate (we'd hit it after ≫10²⁰
  cheques against a single peer); no special handling.

### Operator-side provisioning (new in 0.5.0)

Two new scripts in `bee-clients/scripts/`:

- **`06-deploy-zigbee-chequebook.sh`** — production-shape
  provisioning. Deploys a fresh chequebook via the canonical Sepolia
  factory with zigbee's identity-derived eth address as issuer,
  funds it with sBZZ, writes
  `~/.zigbee/chequebook.json`. Requires foundry's `cast`. One-time,
  per-device, on the operator's machine — chain stays off the
  device. ~$0.001 in Sepolia ETH gas, negligible sBZZ.
- **`05-extract-bee-chequebook.sh`** — *testing only.* Extracts
  bee's already-deployed chequebook + decrypts bee's swarm.key,
  hands them to zigbee. Useful for protocol-wire smoke tests
  (CI-friendly: no chain action). Cannot actually settle since
  bee's chequebook is unfunded for our use; bee's
  bouncing-cheque check rejects.
- **`12-verify-zigbee-swap.sh`** — drives 25× single-chunk
  retrievals through zigbee's daemon with `--chequebook` set, then
  cross-checks bee's `GET /chequebook/cheque` API for an entry
  matching our overlay + cumulative. The earlier log-grep
  heuristic was too strict (bee's accept path is silent).

### Other script changes worth noting

`02-buy-stamp.sh`, `03-upload-file.sh`, and `04-upload-encrypted-file.sh`
now print `export BATCH=…` / `export REF=…` / `export TESTFILE=…`
instead of bare assignments, so the documented
`eval "$(./02-buy-stamp.sh)"` pattern actually exports the values
to subprocesses. Earlier behaviour set them only in the current
shell — silently broken when the next script ran as a child process.

### Numbers

- ~1,356 new lines across 4 new modules (1,025 implementation + 331 tests).
- ~250 lines changed in 4 existing files (`src/identity.zig`,
  `src/main.zig`, `src/p2p.zig`, `src/accounting.zig`).
- ReleaseSafe build: 6.9 MB (was 6.7 MB; +200 KB for the new modules
  and the `cheque/swap/accounting/credential` chain).
- Live-verified end-to-end on Sepolia: deployed chequebook
  `0xcc853f656ede26b73a9d9e2e710f6c506e12d6fa`, 25/25 retrievals,
  8 cheques accepted per session, zero threshold disconnects.
  Re-runnable across sessions thanks to B2 + script-side seeding.
  Total suite: **107/107** unit tests pass (104 from rc1 + 3 new
  for B2: ephemeral mode, deriveStatePath, seedCumulative).
