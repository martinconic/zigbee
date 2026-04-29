# zigbee 0.5.0 — release notes (in progress)

**Status:** the headline of 0.5.0 is **retrieval-maturity**: local
chunk store, encrypted-chunk references, and SWAP cheques (issue-only).
Sub-items land on `main` incrementally; this file accumulates the
notes as each one ships, and 0.5.0 is tagged when all three are done.

| Sub-item | State |
|---|---|
| 0.5a — local flat-file chunk store with basic LRU | ✅ landed |
| 0.5b — encrypted-chunk references (`refLength = 64`) | ✅ landed |
| 0.5c — SWAP cheques (issue-only, no on-chain cashing) | not started |

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

*Not started.* The headline of 0.5. `/swarm/swap/1.0.0/swap`
protocol; we issue cheques to bee peers when our cumulative debt
crosses bee's announced threshold. Receive cheques but defer
cashing on-chain to 1.0. Unblocks unlimited retrieval per peer.
~4–5 weeks FTE.
