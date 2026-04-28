# zigbee — architecture

This document explains *what kind of node* zigbee is, where it sits in
the Swarm protocol stack, what it does on its own vs. what it delegates
to the bee peers it talks to, and the boundaries that follow from those
choices.

If you've read the README and want to understand the runtime model,
start here. If you want the protocol-level wire details, see the
[Swarm Protocol Specification](../docs/swarm_protocol_spec.pdf) and
[Book of Swarm](../docs/the-book-of-swarm-2.pdf) §2.1 (Kademlia routing)
and §2.3 (chunk retrieval and syncing).

---

## 1. What zigbee is — an ultra-light Swarm client

Bee distinguishes "full node" from "light node" via the `light: true`
config flag. Zigbee runs in a mode that's effectively *lighter than light*
— closer to the Book of Swarm's "no-storer client" than even bee's light
mode:

| Capability | Bee full | Bee light | Zigbee |
|---|---|---|---|
| Stores chunks (reserve) | ✅ | ✅ (small) | ❌ |
| Forwards retrievals (acts as multiplexer) | ✅ | ✅ | ❌ |
| Pushes own chunks (with stamps) | ✅ | ✅ | ❌ |
| Pull-syncs from neighbours | ✅ | ✅ | ❌ |
| Settles via SWAP cheques | ✅ | ✅ | ❌ (next phase) |
| Plays redistribution game | ✅ | ❌ | ❌ |
| Maintains saturated Kademlia table | ✅ | partial | ❌ (only the few peers we've handshaken with) |
| Speaks libp2p+swarm protocols correctly | ✅ | ✅ | ✅ |
| Initiates retrieval (downloader) | ✅ | ✅ | ✅ |
| Reassembles multi-chunk files (joiner) | ✅ | ✅ | ✅ |

Bee logs us with `light=" (light)"` once our handshake reports
`full_node = false`. We answer the protocols bee uses to *track* a peer
(Identify, Ping, handshake, hive, pricing announce) but we don't run a
server side for the protocols bee uses to *get work done* (retrieval,
pushsync, pullsync, swap).

## 2. Where zigbee sits in the network

```
                                ┌──────────────────┐
                                │  Swarm network   │
                                │ (Kademlia of     │
                                │  bee full nodes) │
                                └────────┬─────────┘
                                         │ /swarm/retrieval/1.4.0
                                         │ (forwarding-Kademlia,
                                         │  recursive)
                                         │
              ┌────────────┐  hive  ┌────▼─────┐  hive  ┌────────────┐
              │  bee A     │◀──────▶│  bee B   │◀──────▶│  bee C     │
              │ (peer of   │ peers  │  peer of │ peers  │  peer of   │
              │  zigbee)   │        │  zigbee) │        │  zigbee)   │
              └─────┬──────┘        └────┬─────┘        └─────┬──────┘
                    │                    │                     │
                    │ Noise+Yamux+Swarm  │                     │
                    │       handshake    │ (up to              │
                    │                    │  --max-peers)       │
                    │                    │                     │
                    └────────────┬───────┴─────────────────────┘
                                 │
                              ┌──▼───┐
                              │ zigbee│
                              │daemon│
                              └──────┘
                                 ▲
                                 │ HTTP
                                 │ 127.0.0.1:9090
                                 │   /retrieve/<hex>
                                 │   /bzz/<reference>
                                 │   /peers
                                 │
                              ┌──┴───┐
                              │ user │
                              └──────┘
```

### What zigbee does locally

1. **Bootstrap.** Dial one bee (the `--peer` argument; can be a public
   bootnode resolved via `/dnsaddr/...`).
2. **Discover peers** via the hive broadcasts that bee sends right
   after handshake. Each broadcast advertises a batch of overlays +
   underlays.
3. **Auto-dial** up to `--max-peers` direct connections to those bees,
   with per-peer retry/backoff and a 15 s manage tick that re-queues
   unconnected entries.
4. **Hold those connections open**, answering the few protocols bee
   uses for liveness (Identify, Ping, hive responder, pricing
   announce-back).
5. **On a `/retrieve` or `/bzz` API request**, pick the XOR-closest
   *connected* bee for the requested chunk address and open a
   `/swarm/retrieval/1.4.0/retrieval` stream to it. Wait. If that bee
   returns `Delivery{Err}` or the stream resets or the 30 s per-attempt
   timeout fires, fall through to the next-closest connected bee.
   Spec §1.5: "If the response message contains a non empty Err field
   the requesting node closes the stream and then can re-attempt
   retrieving the chunk from the next peer candidate."
6. **For multi-chunk files**, the joiner walks the chunk-tree returned
   by step 5: leaf chunks (`span ≤ payload.len`) yield `payload[0..span]`
   bytes; intermediate chunks contain concatenated 32-byte child
   addresses (branching factor 128) which we recursively fetch.
7. **Validate** every chunk's BMT root against its requested address
   (CAC). SOC chunks are passed through with a logged warning;
   refLength=64 (encrypted) refs aren't yet supported.

### What zigbee delegates to bee

Every step of the *forwarding-Kademlia walk* that finds a chunk's
storer in the network. From the Book of Swarm §2.3.1, Figure 2.6:

> *In Step 1, downloader node D uses Kademlia connectivity to send a
> request for the chunk to a peer storer node that is closer to the
> address. This peer then repeats this until node S is found that has
> the chunk. In other words peers relay the request recursively via
> live peer connections ultimately to the neighbourhood of the chunk
> address (request forwarding). In Step 2 the chunk is delivered along
> the same route using the forwarding steps in the opposite direction
> (response backwarding).*

When zigbee opens a single retrieval stream to bee A:
- A looks up the chunk in its local store.
- If A doesn't have it, A picks *its* closest peer toward the chunk
  (excluding zigbee), opens a retrieval stream to that peer, and
  forwards the request. That peer does the same.
- The chain continues until a bee whose reserve contains the chunk
  returns `Delivery{Data}`, which then *backwards* hop-by-hop along
  the same yamux streams.
- Zigbee receives `Delivery{Data}` on its single stream to A and is
  done.

Each forwarder bee uses bee's per-stream `errorsLeft = 1` budget for
non-origin requests (spec §1.5: *"A 'backwarder' will give up after
the first failure while an 'origin' node might repeat the request
multiple time towards the same peer before giving up."*). That
brittleness is *why* zigbee's origin retry across multiple connected
peers matters — different starting points produce different
forwarding chains.

## 3. Retrieval threading model

Concrete picture of one `GET /bzz/<ref>` request:

```
HTTP API thread (per request)
        │
        ▼
  joiner.join(ref)
        │
        ▼  fetch(ref) ───────────────► retrieveChunkIterating(ref)
        │                                       │
        │                                       ▼
        │                              connectionsSortedByDistance(ref)
        │                                       │
        │                                       ▼  for each peer in XOR-asc order:
        │                              tryRetrieveOnceWithTimeout(...)
        │                                       │
        │                              ┌────────▼────────┐
        │                              │ open yamux      │
        │                              │ stream          │
        │                              ├─────────────────┤
        │                              │ spawn watchdog  │── 30s timer ─┐
        │                              │ thread          │              │
        │                              ├─────────────────┤              │
        │                              │ multistream     │              │
        │                              │ select retrieval│              │
        │                              ├─────────────────┤              │
        │                              │ exchange empty  │  ┌───────────▼─────────┐
        │                              │ Headers         │  │ on timeout:         │
        │                              ├─────────────────┤  │ stream.cancel()     │
        │                              │ write Request   │  │   (RST + signal)    │
        │                              │ read Delivery   │◀─┤ unblocks read with  │
        │                              │  ↓ on success   │  │ error.StreamReset   │
        │                              │  signalDone     │  └─────────────────────┘
        │                              ├─────────────────┤
        │                              │ join watchdog   │
        │                              │ close stream    │
        │                              └─────────────────┘
        │                                       │
        │                              on err: try next peer
        │                                       │
        │                              return chunk_data
        ▼
  walk chunk_data:
    if leaf:       append payload[0..span] to out
    if intermediate: for each 32-byte child addr:
                        recurse → fetch(child) → walk(...)
        │
        ▼
  return file bytes
        │
        ▼
HTTP 200 OK
Content-Length: <span>
<file bytes>
```

Key threading points:
- **Each HTTP request runs on its own thread** (spawned in `serveApi`).
- **Each yamux stream multiplexes over the same TCP connection** to a
  bee peer; concurrent `/retrieve` and `/bzz` requests open independent
  streams.
- **The watchdog is one thread per retrieval attempt** using
  `Condition.timedWait`. The happy path wakes immediately on
  `signalDone()`; only a hung peer eats the full 30 s.
- **Each `Connection` has its own accept-loop thread** dispatching
  inbound peer-initiated streams (Identify, Ping, hive, pricing) via a
  caller-supplied dispatcher. Mutexes guard `connections`,
  `peers`, and `hive_candidate_overlays`.

## 4. The accounting wall

Bee's accounting layer is what makes the network sustainable but it's
also what bounds zigbee's reach without SWAP support.

When zigbee retrieves a chunk from bee A:
- A's `Pricer.Price(chunk)` charges proximity-weighted price (10 000 ×
  (32 − PO) wei → 10 000 wei when chunk is in A's neighbourhood,
  ~320 000 wei when far). Default `poPrice = 10 000`.
- A debits zigbee's account with that amount.
- A's `disconnect threshold` for our debt is **1 350 000 wei**.
  Once we cross it, A logs `apply debit: disconnect threshold exceeded`
  and disconnects us with `error="apply debit: disconnect threshold exceeded"`.

Empirically this caps single-peer retrieval at ~25–30 chunks (~100 KB
of file content). A 700 KB file with ~175 chunks fails mid-walk.

Mitigations that don't fix it:
- Iteration through `--max-peers` *N* bees → each peer has its own
  credit window → effective budget is N × ~25 chunks. Helps until you
  ask for a file larger than that combined budget.
- Reconnecting (kill+relaunch zigbee) gives a fresh identity → fresh
  debt counter. But the libp2p key isn't persisted between runs, so
  this is a workaround, not a feature.

The proper fix is Phase 6 — implement `/swarm/swap/1.0.0/swap`, sign
cheques against a chequebook contract, and exchange them periodically
to settle accumulated debt. That requires Ethereum RPC integration and
chequebook-contract bindings, both of which are real chunks of work.

## 5. What can and can't be retrieved today

| What | Result |
|---|---|
| File ≤ 4 KB uploaded via `bee /bytes` (CAC root, single leaf) | ✅ Works |
| File between 4 KB and ~100 KB (CAC root + child leaves, fits one peer's credit window) | ✅ Works (verified live: 10 000 B byte-identical) |
| File 100 KB – ~400 KB on `--max-peers 4` (fits combined credit window) | Works in principle until first peer disconnects; iteration falls through |
| File > combined credit window | ❌ Fails mid-walk with `BrokenPipe` after bee disconnects us |
| Single SOC chunk (e.g. feed root) via `/retrieve/<hex>` | ✅ Works (returns raw chunk bytes) |
| SOC reference fed to `/bzz/<ref>` | ❌ 502 with `LikelySocReference` (spans don't make sense; we detect and reject) |
| Encrypted-chunk reference (refLength = 64) | ❌ Not implemented |
| Reference + path (`/bzz/<ref>/<path>`) | ❌ No manifest walker |
| Push (upload) | ❌ No postage stamps; on-chain integration deferred |

## 6. Pointers into the code

| Concept | File |
|---|---|
| HTTP API entry + routing | `src/p2p.zig` (`serveApi`, `handleApi`, `handleRetrieveApi`, `handleBzzApi`) |
| Multi-peer iteration (spec §1.5 origin retry) | `src/p2p.zig` (`P2PNode.retrieveChunkIterating`, `connectionsSortedByDistance`) |
| 30 s per-attempt watchdog | `src/p2p.zig` (`Watchdog`, `tryRetrieveOnceWithTimeout`) + `src/yamux.zig` (`Stream.cancel`) |
| Auto-dialer + manage tick | `src/p2p.zig` (`runHiveDialer`, `requeueUnconnectedPeers`, `MANAGE_TICK_NS`) |
| Chunk-tree walk | `src/joiner.zig` (`join`, `walk`) |
| Forwarding-Kademlia retrieval (initiator) | `src/retrieval.zig` |
| Hive discovery responder | `src/hive.zig` |
| Bee handshake | `src/bee_handshake.zig` |
| Per-connection lifecycle | `src/connection.zig` |
