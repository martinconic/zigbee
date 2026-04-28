# zigbee 0.4 — release notes

**Date:** 2026-04-28
**Goal:** make zigbee a drop-in replacement for bee's read-only REST API.
**Status:** ✅ achieved — bee tools that consume `/health`, `/addresses`,
`/peers`, `/topology`, `/chunks/<addr>`, `/bytes/<ref>`, `/bzz/<ref>`,
`/bzz/<ref>/<path>` can point at zigbee unchanged.

## Headline

```bash
$ ./zig-out/bin/zigbee --peer 127.0.0.1:1634 --network-id 10 daemon &

$ curl -s http://127.0.0.1:9090/health | jq
{ "status": "ok", "version": "0.3.0-zigbee", "apiVersion": "5.0.0" }

$ curl -s http://127.0.0.1:9090/node | jq
{ "beeMode": "ultra-light", "chequebookEnabled": false, "swapEnabled": false }

$ curl -s http://127.0.0.1:9090/addresses | jq
{
  "overlay": "51d373b5a11708e37ccf099a6fb2b706f57e5a180f6353ba46ce11fd2c802211",
  "underlay": [],
  "ethereum": "0x34520e360fa80d5e8f40c4800f89596fb8580e3e",
  "chain_address": "0x34520e360fa80d5e8f40c4800f89596fb8580e3e",
  "publicKey": "02004c63364f286fec93da95e5c60bdd060e2725ea15e603f60fb33c8127584146",
  "pssPublicKey": "02004c63364f286fec93da95e5c60bdd060e2725ea15e603f60fb33c8127584146"
}

$ curl -s -o file.bin "http://127.0.0.1:9090/bzz/<manifest-ref>/<filename>"
$ cmp file.bin <(curl -s http://127.0.0.1:1633/bzz/<manifest-ref>/<filename>)
# byte-identical
```

## What's new since 0.3

0.3 had a small zigbee-native HTTP API (`/retrieve`, `/bzz`, `/peers`).
0.4 reshapes the API to bee's exact JSON contracts and adds the
operationally-essential identity / health / topology endpoints.

| Endpoint | Method | Status |
|---|---|---|
| `/health` | GET | **NEW** — bee-shape, `{"status":"ok","version":"...","apiVersion":"..."}` |
| `/readiness` | GET | **NEW** — alias of `/health` |
| `/node` | GET | **NEW** — bee-shape, reports `beeMode: "ultra-light"` |
| `/addresses` | GET | **NEW** — overlay, ethereum, chain_address, publicKey, pssPublicKey |
| `/peers` | GET | **RESHAPED** — bee-shape `{"peers":[{"address":"<overlay>","fullNode":bool}]}` (was zigbee-native `{"connected":[…],"known":N}`) |
| `/topology` | GET | **NEW** — kademlia bin populations, base address, total connected |
| `/chunks/<addr>` | GET | **NEW** — bee-shape raw chunk = `span(8) ‖ payload`, `Content-Type: binary/octet-stream` |
| `/bytes/<ref>` | GET | **NEW** — bee-shape, joiner over `<ref>`, no manifest detection (matches `bee POST /bytes` ↔ `bee GET /bytes/<ref>` semantics) |
| `/bzz/<ref>` | GET | unchanged (manifest-aware, default-doc resolution) |
| `/bzz/<ref>/<path>` | GET | **NEW** — bee-shape, manifest path lookup via the existing `mantaray.lookup` walker |
| `/retrieve/<hex>` | GET | unchanged (zigbee-native legacy: payload-only + `X-Chunk-Span` header) |

## Live verification (against local bee with the `d7c5e8fe…` manifest from this session)

```
GET /chunks/<addr>          200, 360 bytes  ← byte-identical to bee
GET /bytes/<inner-ref>      200, 2742 bytes ← byte-identical to bee
GET /bzz/<manifest-ref>     200, 2742 bytes ← byte-identical to bee
GET /bzz/<manifest>/<path>  200, 2742 bytes ← byte-identical to bee
GET /health                 200, JSON parses, status=ok
GET /node                   200, JSON parses, beeMode=ultra-light
GET /addresses              200, JSON parses, all hex fields well-formed
GET /peers                  200, JSON parses with bee shape
GET /topology               200, JSON parses
```

## What zigbee specifically can NOT serve as bee-compatible

These all need state we don't have. Hitting them returns `404 unknown
path` today (we could change to bee-shape `503` with a "not supported"
message — let me know if that's preferred).

| Endpoint | Why we can't yet |
|---|---|
| `POST /bytes`, `POST /bzz`, `POST /chunks` | No upload / no postage stamps / no chain integration |
| `POST /stamps`, `GET /stamps[/<batch>]` | Postage stamps live on-chain |
| `GET /chequebook/*` | Requires chequebook contract calls |
| `GET /settlements`, `GET /balances` | Requires accounting + SWAP |
| `GET /chainstate` | Requires Ethereum RPC client |
| `GET /reservestate` | We have no local reserve |
| `GET /pins`, `PUT /pins/...` | Requires local chunk store |
| `GET /tags`, `POST /tags` | Tags only exist for local uploads |
| `GET /pingpong/<peer>` | Initiator side of `/ipfs/ping/1.0.0` not wired to the API; ~30 lines to add if we want it |

## What's still in front of arbitrarily-large file retrieval

Same as 0.3: bee's per-peer accounting (`disconnect threshold = 1 350 000 wei`,
~25–30 chunks per peer per session) caps unpaid retrieval. SWAP cheques
(Phase 6) is the unblocker; nothing the API surface can do about it.

## Numbers

- ~7,900 lines of Zig in 27 modules.
- 62 / 62 unit tests pass.
- 1 vendored C dep (`libsecp256k1`); 0 Go/Rust deps.
- Live verified byte-identical to bee on `/chunks/<addr>`,
  `/bytes/<ref>`, `/bzz/<ref>`, `/bzz/<ref>/<path>`.

## CLI surface

Unchanged from 0.3:

```
zigbee [--peer ip:port] [--network-id N] [SUBCOMMAND ...]

subcommands:
  (none)              dial the peer, do the handshake, stay connected
  resolve <host>      /dnsaddr lookup, then exit
  retrieve <hex> [-o file]
                      retrieve one chunk by content address, then exit
  daemon [--max-peers N] [--api-port P]
                      bee-compatible HTTP API on 127.0.0.1:P (default 9090)
```

## Build

```bash
zig build           # → zig-out/bin/zigbee
zig build test      # → 62/62
```

Requires Zig 0.15.x and a C toolchain.
