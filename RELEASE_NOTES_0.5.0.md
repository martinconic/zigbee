# zigbee 0.5.0 — release notes (in progress)

**Status:** the headline of 0.5.0 is **retrieval-maturity**: local
chunk store, encrypted-chunk references, and SWAP cheques (issue-only).
Sub-items land on `main` incrementally; this file accumulates the
notes as each one ships, and 0.5.0 is tagged when all three are done.

| Sub-item | State |
|---|---|
| 0.5a — local flat-file chunk store with basic LRU | ✅ landed |
| 0.5b — encrypted-chunk references (`refLength = 64`) | not started |
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

*Not started.* Refs carry 32 B addr ‖ 32 B sym key. Joiner +
mantaray walker need to honour 64-byte refs and decrypt payloads
with the per-ref symmetric key. ~2 weeks FTE.

## 0.5c — SWAP cheques (issue-only, no on-chain cashing)

*Not started.* The headline of 0.5. `/swarm/swap/1.0.0/swap`
protocol; we issue cheques to bee peers when our cumulative debt
crosses bee's announced threshold. Receive cheques but defer
cashing on-chain to 1.0. Unblocks unlimited retrieval per peer.
~4–5 weeks FTE.
