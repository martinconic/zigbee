# zigbee 0.4.2 — release notes

**Date:** 2026-04-29
**Goal:** clear the three smaller pending items left over after 0.4.1
before starting 0.5.0 retrieval-maturity. Operational polish, no new
protocol coverage.
**Status:** ✅ all three landed; 74/74 unit tests pass; ReleaseSafe
build succeeds at ~6.3 MB.

## Headline

```bash
$ ./zig-out/bin/zigbee --peer <bee> --network-id 10 daemon &
# A handshake no longer floods stderr with 10 lines of
# "Initializing Noise Handshake as RESPONDER..." per peer.

$ # Bee analogue: POST /pingpong/<overlay> against an already-connected peer.
$ curl -s -X POST http://127.0.0.1:9090/pingpong/$(curl -s http://127.0.0.1:9090/peers | jq -r '.peers[0].address')
{"rtt":"1.234ms"}

$ # Ctrl-C (or kill -TERM) drains cleanly:
^C
[api] shutdown — stopped accepting connections
[daemon] shutting down — waiting for dialer to exit
[daemon] dialer joined; closing connections
# Bee no longer logs "broadcast failed" on the other side.
```

## What's new since 0.4.1

| Patch | Subject | Why it matters |
|---|---|---|
| 0.4.2a | Strip Noise XX hot-path debug prints | Each peer dial used to dump 10 `std.debug.print` lines from `processHandshakeInitiator` / `processHandshakeResponder` ("Initializing Noise…", "Sent Initiator Ephemeral Key…", "Successfully decrypted remote static key", etc.). Daemon-mode log was unreadable once two or three peers were connected. Per-attempt `[dialer]` and `[retrieve]` logs in `p2p.zig` are kept — those are still useful for development. (Was task #9 in STATUS.md.) |
| 0.4.2b | `POST /pingpong/<overlay>` HTTP endpoint | bee-shape: matches `pkg/api/pingpong.go`. Looks up an already-connected peer by overlay, opens a yamux stream, runs `/ipfs/ping/1.0.0` once, returns `{"rtt":"<duration>"}` with the duration formatted Go-style (`5.234ms`, `1.234s`, etc.). Returns 404 `{"code":404,"message":"peer not found"}` when the peer isn't in our connection list (matches bee's `p2p.ErrPeerNotFound` path). |
| 0.4.2c | Graceful shutdown on SIGINT / SIGTERM | Daemon previously ran until `SIGKILL`; the TCP RST on process exit caused bee to log `"broadcast failed"`. Now SIGINT/SIGTERM flips a module-level atomic; the API listener polls it (200 ms tick) and returns; the hive dialer checks it at every loop iteration; `daemonRun` joins the dialer; `defer node.deinit()` in `main` closes every live connection cleanly via the existing `Connection.deinit` chain. |

## 0.4.2a — strip Noise XX hot-path prints

10 `std.debug.print` lines removed from `src/noise.zig`:

| Line (pre-patch) | Message |
|---|---|
| 189 | `Initializing Noise Handshake as RESPONDER...` |
| 302 | `Initializing Noise Handshake as INITIATOR...` |
| 311 | `Sent Initiator Ephemeral Key (\`e\`). Waiting for Responder...` |
| 316 | `Received message 2 from Responder. Length: {d} bytes` |
| 335 | `Successfully decrypted remote static key.` |
| 345 | `Successfully decrypted Responder's NoiseHandshakePayload!` |
| 369 | `Responder signature verification FAILED: {any}` |
| 372 | `Responder signature VALID (key_type={d}).` |
| 444 | `Sent message 3 (\`s\`, \`se\`). Noise Handshake Complete!` |
| 449 | `Transport phase initialized.` |

The signature-FAILED line at 369 is folded into the existing
`return error.HandshakeFailed`; the upstream caller already
distinguishes that error from "stream broken" and logs accordingly.

The proper logging refactor (X4 — log levels, JSON output, `--log-level`
flag) is still planned for early 0.6 per `docs/iot-roadmap.html` §4.
This patch is just the noisy-by-default culprit on the handshake path.

## 0.4.2b — `POST /pingpong/<peer-overlay>`

**Wire:** plain HTTP/1.1 POST, path is `/pingpong/<64-char-hex-overlay>`,
body is ignored.

**Behaviour:**
1. Walk `node.connections` under the connections mutex; find the live
   (non-dead) connection whose `peer_overlay == requested overlay`.
2. If not found → `404 {"code":404,"message":"peer not found"}`.
3. Open a new yamux stream on that connection.
4. Run `/ipfs/ping/1.0.0` (32-byte nonce out, 32-byte echo back).
5. Return `200 {"rtt":"<duration>"}` with the round-trip in Go's
   `time.Duration.String()` format.

**Go-style duration formatter** lives in `src/p2p.zig` as
`formatGoDuration(out: []u8, ns: u64)`. Picks the largest unit such
that the integer part is ≥ 1 and prints up to 3 fractional digits with
zero-padding (e.g. `5.234µs`, `1.234ms`, `12.500s`). Unit-tested with 8
golden samples covering the ns/µs/ms/s ranges and the zero case.

**404 shape** matches bee's `jsonhttp.NotFound` (`{"code":N,"message":"…"}`).
Other errors (openStream failed, ping mismatch, EOF, …) return
`500 {"code":500,"message":"…"}` — close enough for tooling that
reads the `code` field.

## 0.4.2c — graceful shutdown on SIGINT / SIGTERM

**The bug** was cosmetic but persistent: `zigbee daemon` had no way to
exit cleanly. Ctrl-C → process killed → kernel sent TCP RSTs to every
bee peer → each bee logged `"broadcast failed"` once, sometimes
followed by `"failed to send message"` from its hive broadcaster. The
local socket state survived (no leaked fds) because process exit reaps
everything, but the noise upstream was avoidable.

**The fix:**

- **Module-level atomic flag** in `src/p2p.zig`:
  `var g_shutdown: std.atomic.Value(bool)`. Signal handlers can only
  do async-signal-safe work, so the handler does *only* `g_shutdown.store(true)`.
- **Signal handler** installed via `std.posix.sigaction` in `daemonRun`
  for `SIGINT` and `SIGTERM`. Uses `sigemptyset()` for the mask — no
  signal blocking during the handler's single atomic store.
- **API server (`serveApi`)** wraps `accept()` in `std.posix.poll(.., 200 ms)`;
  re-checks `g_shutdown` between polls so the worst-case shutdown
  latency is one tick. accept() itself stays blocking (poll already
  said the listener is readable). On shutdown the loop returns and
  `defer server.deinit()` closes the listener fd.
- **Hive dialer (`runHiveDialerInner`)** checks `g_shutdown.load(.acquire)`
  at the top of each iteration. Worst-case 2 s shutdown latency
  (matches its existing internal sleep cadence).
- **`daemonRun`** stops detaching the dialer thread — keeps the
  `std.Thread` handle and `join()`s it after `serveApi` returns.
  After the join, `main`'s `defer node.deinit()` runs `Connection.deinit`
  for every live peer (closes TCP, joins yamux reader, joins accept
  thread). bee sees a clean FIN.

**Caveats** (deliberate scope cuts; promote to issues if they bite):

- We do **not** proactively send Yamux GoAway frames before closing.
  bee's reader sees TCP EOF and ends its session normally; that's
  enough to suppress "broadcast failed". Adding a real GoAway is a
  ≤10-line follow-up if we ever observe a peer that needs it.
- Detached per-API-request handler threads (`handleApi`) are not
  joined — if a request is mid-handler when shutdown fires, it'll
  finish on its own and the OS reaps it on process exit. Long-running
  request paths (`/bzz` retrieving a 1 GB file) would extend exit
  time; in practice retrievals are 30-second-bounded by the watchdog.
- Watchdog threads from `tryRetrieveOnceWithTimeout` are joined per-attempt
  inline, so they don't leak.

## Numbers

- 8,840 lines of Zig across 28 modules (small net delta: −10 print
  lines in `noise.zig`, +95 in `p2p.zig` for pingpong + shutdown +
  duration formatter + tests).
- **74 / 74** unit tests pass (was 73 in 0.4.1; +1 for
  `formatGoDuration` golden samples).
- ReleaseSafe build size: 6.3 MB (was 6.0 MB; +0.3 MB from `std.posix.poll`
  + sigaction pulled in).

## Build

```bash
zig build           # → zig-out/bin/zigbee
zig build test      # → 74/74
zig build -Doptimize=ReleaseSafe   # → ~6.3 MB
```

Requires Zig 0.15.x and a C toolchain.
