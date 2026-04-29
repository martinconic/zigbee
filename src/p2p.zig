const std = @import("std");
const identity = @import("identity.zig");
const noise = @import("noise.zig");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");
const identify = @import("identify.zig");
const ping = @import("ping.zig");
const multiaddr = @import("multiaddr.zig");
const peer_id = @import("peer_id.zig");
const bee_handshake = @import("bee_handshake.zig");
const pricing = @import("pricing.zig");
const hive = @import("hive.zig");
const peer_table = @import("peer_table.zig");
const bzz_address = @import("bzz_address.zig");
const retrieval = @import("retrieval.zig");
const joiner = @import("joiner.zig");
const mantaray = @import("mantaray.zig");
const bmt = @import("bmt.zig");
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const store_mod = @import("store.zig");
const encryption = @import("encryption.zig");
const cheque_mod = @import("cheque.zig");
const swap_mod = @import("swap.zig");
const accounting_mod = @import("accounting.zig");
const credential_mod = @import("credential.zig");
const net = std.net;

/// libp2p protocols this node speaks. Advertised in Identify and accepted on
/// inbound streams.
const SUPPORTED_PROTOCOLS = [_][]const u8{
    identify.PROTOCOL_ID,
    ping.PROTOCOL_ID,
    bee_handshake.PROTOCOL_ID,
    pricing.PROTOCOL_ID,
    hive.PROTOCOL_ID,
    "/yamux/1.0.0",
};

/// Daemon-mode shutdown flag. Set from a SIGINT/SIGTERM handler (signal
/// handlers can only do async-signal-safe work, so the handler does
/// nothing but flip this atomic). The serveApi loop polls it; the hive
/// dialer checks it at every iteration; daemonRun joins both threads
/// before returning so `defer node.deinit()` in main can close all live
/// connections cleanly (FIN), avoiding the "broadcast failed" log line
/// bee emits when our process-exit RST drops the TCP session abruptly.
var g_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleShutdownSignal(_: c_int) callconv(.c) void {
    g_shutdown.store(true, .release);
}

fn installSignalHandlers() !void {
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// Optional task to perform after a one-shot dial completes the bee
/// handshake. Set by main.zig from CLI args.
pub const PostHandshakeAction = union(enum) {
    none,
    retrieve: struct {
        address: [bmt.HASH_SIZE]u8,
        /// Optional decryption key. Present when the user passed a
        /// 128-char hex reference (32-byte addr ‖ 32-byte symmetric key).
        /// When present, the retrieved chunk is decrypted before being
        /// written/printed.
        key: ?[encryption.KEY_LEN]u8 = null,
        out_path: ?[]const u8, // null ⇒ print to stdout as hex
    },
};

pub const P2PNode = struct {
    allocator: std.mem.Allocator,
    id: identity.Identity,
    network_id: u64,
    nonce: [bzz_address.NONCE_LEN]u8,
    overlay: [bzz_address.OVERLAY_LEN]u8,

    /// Peers we've heard about (via hive) plus those we're connected to.
    /// Hive-only entries are advisory; connected ones have a Connection
    /// pointer in `connections`.
    peers: peer_table.PeerTable,

    /// Active outbound connections. Owned (each pointer is heap-allocated).
    connections: std.ArrayList(*Connection) = .{},
    connections_mtx: std.Thread.Mutex = .{},

    /// In daemon mode, hive broadcasts go through this channel so the
    /// daemon worker can dial new peers as candidates arrive.
    hive_candidate_overlays: std.ArrayList([bzz_address.OVERLAY_LEN]u8) = .{},
    hive_mtx: std.Thread.Mutex = .{},

    /// Guards `peers`. Multiple inbound hive responders (one per Connection
    /// accept thread) can write here concurrently, and the dialer reads.
    peers_mtx: std.Thread.Mutex = .{},

    /// Local chunk store (0.5a). Null = caching disabled. Owned by the
    /// caller (passed in via init); deinit's it on P2PNode.deinit.
    store: ?*store_mod.Store = null,

    /// Per-peer SWAP accounting (0.5c). Always non-null in normal operation
    /// — tracks debt even when no chequebook credential is loaded so the
    /// flag becomes a one-line toggle (`--chequebook PATH`) rather than a
    /// rebuild. Owned by P2PNode; deinit'd on `deinit`.
    accounting: ?*accounting_mod.Accounting = null,

    /// Chequebook credential for cheque issuance (0.5c). Null → accounting
    /// tracks but never issues; bee's disconnect threshold stays the
    /// retrieval ceiling (current pre-0.5c behaviour).
    chequebook: ?credential_mod.ChequebookCredential = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: identity.Identity,
        network_id: u64,
        /// 32-byte bzz overlay nonce. The caller is responsible for
        /// persistence — see `identity.loadOrCreate` which loads/saves
        /// it alongside the libp2p key. Without persistence the
        /// overlay changes every restart and bee's per-peer
        /// accounting state resets.
        nonce: [bzz_address.NONCE_LEN]u8,
        /// Optional local chunk store. Pass null to disable caching.
        /// Ownership transfers — deinit'd on P2PNode.deinit.
        store: ?*store_mod.Store,
        /// Optional accounting tracker (0.5c). Ownership transfers.
        accounting: ?*accounting_mod.Accounting,
        /// Optional chequebook credential (0.5c). When set, accounting
        /// triggers EIP-712-signed cheque issuance.
        chequebook: ?credential_mod.ChequebookCredential,
    ) !P2PNode {
        var overlay: [bzz_address.OVERLAY_LEN]u8 = undefined;
        id.overlayAddress(network_id, nonce, &overlay);
        return .{
            .allocator = allocator,
            .id = id,
            .network_id = network_id,
            .nonce = nonce,
            .overlay = overlay,
            .peers = peer_table.PeerTable.init(allocator, overlay),
            .store = store,
            .accounting = accounting,
            .chequebook = chequebook,
        };
    }

    pub fn deinit(self: *P2PNode) void {
        self.connections_mtx.lock();
        for (self.connections.items) |c| c.deinit();
        self.connections.deinit(self.allocator);
        self.connections_mtx.unlock();
        self.peers.deinit();
        self.hive_candidate_overlays.deinit(self.allocator);
        if (self.store) |s| s.deinit();
        if (self.accounting) |a| a.deinit();
    }

    /// Adds a peer-overlay to the "candidates to dial" queue. Called from
    /// the hive responder; daemon mode picks these off in a worker.
    pub fn enqueueHiveCandidate(self: *P2PNode, overlay: [bzz_address.OVERLAY_LEN]u8) !void {
        self.hive_mtx.lock();
        defer self.hive_mtx.unlock();
        try self.hive_candidate_overlays.append(self.allocator, overlay);
    }

    pub fn dequeueHiveCandidate(self: *P2PNode) ?[bzz_address.OVERLAY_LEN]u8 {
        self.hive_mtx.lock();
        defer self.hive_mtx.unlock();
        if (self.hive_candidate_overlays.items.len == 0) return null;
        return self.hive_candidate_overlays.orderedRemove(0);
    }

    /// Adds a connection to the host's list. Spawns its accept loop with
    /// the per-stream dispatcher.
    fn registerConnection(self: *P2PNode, conn: *Connection) !void {
        self.connections_mtx.lock();
        defer self.connections_mtx.unlock();
        try self.connections.append(self.allocator, conn);
        try conn.startAcceptLoop(@ptrCast(self), &dispatchInboundStream);
    }

    /// Returns the active connection whose peer-overlay is closest (by XOR
    /// distance) to `target`. Skips connections whose accept thread has
    /// exited (`isDead()`) — those will be reaped by the next manage tick.
    /// Returns null if there are no live connections.
    pub fn closestConnectionTo(self: *P2PNode, target: [bzz_address.OVERLAY_LEN]u8) ?*Connection {
        self.connections_mtx.lock();
        defer self.connections_mtx.unlock();
        if (self.connections.items.len == 0) return null;

        var best: ?*Connection = null;
        var best_distance: [bzz_address.OVERLAY_LEN]u8 = [_]u8{0xFF} ** bzz_address.OVERLAY_LEN;
        for (self.connections.items) |c| {
            if (c.isDead()) continue;
            var d: [bzz_address.OVERLAY_LEN]u8 = undefined;
            for (c.peer_overlay, target, 0..) |x, y, i| d[i] = x ^ y;
            if (std.mem.order(u8, &d, &best_distance) == .lt) {
                best = c;
                best_distance = d;
            }
        }
        return best;
    }

    /// Returns all *live* connections, sorted ascending by XOR distance
    /// from each peer's overlay to `target` — closest first. Dead
    /// connections (accept thread already exited) are filtered out so
    /// retrieval iteration doesn't waste an attempt on a guaranteed
    /// `BrokenPipe`. Caller owns the returned slice.
    pub fn connectionsSortedByDistance(
        self: *P2PNode,
        allocator: std.mem.Allocator,
        target: [bzz_address.OVERLAY_LEN]u8,
    ) ![]*Connection {
        self.connections_mtx.lock();
        defer self.connections_mtx.unlock();

        // First pass: count live connections so we can allocate the
        // exact slice (instead of allocating items.len and shrinking).
        var live_count: usize = 0;
        for (self.connections.items) |c| {
            if (!c.isDead()) live_count += 1;
        }

        const out = try allocator.alloc(*Connection, live_count);
        var idx: usize = 0;
        for (self.connections.items) |c| {
            if (c.isDead()) continue;
            out[idx] = c;
            idx += 1;
        }

        const Ctx = struct {
            t: [bzz_address.OVERLAY_LEN]u8,
            fn lessThan(ctx: @This(), a: *Connection, b: *Connection) bool {
                var da: [bzz_address.OVERLAY_LEN]u8 = undefined;
                var db: [bzz_address.OVERLAY_LEN]u8 = undefined;
                for (a.peer_overlay, ctx.t, 0..) |x, y, i| da[i] = x ^ y;
                for (b.peer_overlay, ctx.t, 0..) |x, y, i| db[i] = x ^ y;
                return std.mem.order(u8, &da, &db) == .lt;
            }
        };
        std.mem.sort(*Connection, out, Ctx{ .t = target }, Ctx.lessThan);
        return out;
    }

    /// Count of *live* connections (filters out connections whose
    /// accept thread has exited). Used by the dialer to decide
    /// whether to look for new peers — counting dead conns would
    /// make the dialer think we're full and never re-fill.
    pub fn connectionCount(self: *P2PNode) usize {
        self.connections_mtx.lock();
        defer self.connections_mtx.unlock();
        var n: usize = 0;
        for (self.connections.items) |c| {
            if (!c.isDead()) n += 1;
        }
        return n;
    }

    pub fn isConnectedToOverlay(self: *P2PNode, overlay: [bzz_address.OVERLAY_LEN]u8) bool {
        self.connections_mtx.lock();
        defer self.connections_mtx.unlock();
        for (self.connections.items) |c| {
            if (std.mem.eql(u8, &c.peer_overlay, &overlay)) return true;
        }
        return false;
    }

    pub fn peersLock(self: *P2PNode) void {
        self.peers_mtx.lock();
    }
    pub fn peersUnlock(self: *P2PNode) void {
        self.peers_mtx.unlock();
    }

    /// Walk `connections`, remove any whose accept-thread has exited
    /// (yamux session ended → peer disconnected, TCP reset, accounting
    /// kick, etc.), and `deinit` them. Two-phase to avoid holding the
    /// connections lock across a potentially-blocking `Connection.deinit`
    /// (which joins yamux reader + accept threads).
    ///
    /// Closes the memory leak from before 0.4.1: previously, dead
    /// connections accumulated in `node.connections` indefinitely;
    /// retrievals against them failed fast with `BrokenPipe` and the
    /// origin-retry loop moved on, but the Connection objects + their
    /// underlying TCP/Noise/Yamux structs were never freed.
    pub fn pruneDeadConnections(self: *P2PNode) !void {
        // Phase 1: under the lock, identify dead connections and
        // detach them from the tracking list.
        var to_deinit = std.ArrayList(*Connection){};
        defer to_deinit.deinit(self.allocator);

        self.connections_mtx.lock();
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const c = self.connections.items[i];
            if (c.isDead()) {
                try to_deinit.append(self.allocator, c);
                _ = self.connections.swapRemove(i);
                // Don't advance i — swapRemove dropped a (possibly
                // live) connection from the tail into slot i.
            } else {
                i += 1;
            }
        }
        self.connections_mtx.unlock();

        // Phase 2: deinit outside the lock. Each `c.deinit()` joins
        // the (already-exited) accept thread + the yamux reader.
        for (to_deinit.items) |c| {
            std.debug.print(
                "[prune] reaping dead connection: peer {s}\n",
                .{std.fmt.bytesToHex(c.peer_overlay, .lower)},
            );
            c.deinit();
        }
    }

    /// Per-attempt timeout matching bee's RetrieveChunkTimeout.
    pub const PER_ATTEMPT_TIMEOUT_NS: u64 = 30 * std.time.ns_per_s;

    /// Retrieves a single chunk by address.
    ///
    /// 1. **Cache lookup** (0.5a): if a local store is configured and
    ///    holds `addr`, return immediately. The cache hit reuses the
    ///    bytes we wrote on a previous fetch — no network round-trip,
    ///    no SWAP cost, no retrieval-timeout exposure.
    /// 2. **Network fetch** (forwarding-Kademlia origin retries):
    ///    iterate connected peers in XOR-asc order; on PeerError /
    ///    stream-reset / per-attempt timeout (30 s), fall through to
    ///    the next peer. This is the spec §1.5 "next peer candidate"
    ///    behaviour and the zigbee equivalent of bee's
    ///    `errorsLeft = maxOriginErrors`.
    /// 3. **Cache write-back** (0.5a): on a successful network fetch,
    ///    insert the bytes into the local store. Best-effort — a put
    ///    failure is logged but never fails the request.
    ///
    /// Returns a heap-allocated `RetrievedChunk`. Caller calls `.deinit()`.
    pub fn retrieveChunkIterating(
        self: *P2PNode,
        addr: [bmt.HASH_SIZE]u8,
    ) !retrieval.RetrievedChunk {
        // Cache lookup.
        if (self.store) |s| {
            const cached = s.get(addr) catch |e| blk: {
                std.debug.print("[store] get failed for {s}: {any}\n", .{
                    std.fmt.bytesToHex(addr, .lower), e,
                });
                break :blk null;
            };
            if (cached) |c| {
                // Convert to RetrievedChunk shape, transferring ownership
                // of `c.data`. We don't track a stamp here — cached chunks
                // are emitted without one (callers don't currently look at
                // it on the read path). The empty stamp slice still has
                // to be allocator-owned so RetrievedChunk.deinit can
                // free it uniformly with network-fetched chunks.
                const empty_stamp = try self.allocator.alloc(u8, 0);
                return retrieval.RetrievedChunk{
                    .data = c.data,
                    .span = c.span,
                    .address = addr,
                    .stamp = empty_stamp,
                    ._allocator = self.allocator,
                };
            }
        }

        const candidates = try self.connectionsSortedByDistance(self.allocator, addr);
        defer self.allocator.free(candidates);
        if (candidates.len == 0) return error.NoConnectedPeers;

        std.debug.print(
            "[retrieve] {s}: trying {d} peers in XOR-asc order\n",
            .{ std.fmt.bytesToHex(addr, .lower), candidates.len },
        );

        var last_err: anyerror = error.NoCandidates;
        for (candidates, 0..) |conn, i| {
            std.debug.print(
                "[retrieve] attempt {d}/{d} → peer {s}\n",
                .{ i + 1, candidates.len, std.fmt.bytesToHex(conn.peer_overlay, .lower) },
            );
            if (tryRetrieveOnceWithTimeout(self.allocator, conn, addr, PER_ATTEMPT_TIMEOUT_NS)) |rc| {
                // Cache write-back: best-effort. A failure here (full
                // disk, permission denied, …) shouldn't fail the
                // retrieval that already succeeded.
                if (self.store) |s| {
                    s.put(addr, rc.span, rc.data) catch |e| {
                        std.debug.print("[store] put failed for {s}: {any}\n", .{
                            std.fmt.bytesToHex(addr, .lower), e,
                        });
                    };
                }
                // SWAP accounting + cheque issuance (0.5c). Best-effort.
                self.chargeAndMaybeIssue(conn) catch |e| {
                    std.debug.print(
                        "[swap] charge/issue against {s} failed: {any}\n",
                        .{ std.fmt.bytesToHex(conn.peer_overlay, .lower), e },
                    );
                };
                return rc;
            } else |e| {
                last_err = e;
                std.debug.print(
                    "[retrieve] attempt {d} failed against {s}: {any}\n",
                    .{ i + 1, std.fmt.bytesToHex(conn.peer_overlay, .lower), e },
                );
            }
        }
        return last_err;
    }

    /// Per-retrieval SWAP hook (0.5c).
    ///
    /// 1. Charge the per-peer chunk counter (always — accounting tracks debt
    ///    even when no chequebook is loaded).
    /// 2. If the trigger threshold has been crossed AND a chequebook
    ///    credential is available, build + sign + send a cheque on a fresh
    ///    swap stream against the same connection. Bee receives, validates
    ///    the EIP-712 signature, calls factory.VerifyChequebook on the
    ///    contract address (chain RPC), and on success credits us — the
    ///    per-peer disconnect threshold counter resets in bee's view.
    /// 3. On any failure (no credential, swap negotiation rejected,
    ///    factory verification fails on bee's side), log but do not raise:
    ///    we'll naturally retry on the next retrieval that re-trips the
    ///    threshold.
    fn chargeAndMaybeIssue(self: *P2PNode, conn: *Connection) !void {
        const acc = self.accounting orelse return; // tracking disabled (test paths)
        const should_issue = try acc.charge(conn.peer_overlay, 1);
        if (!should_issue) return;

        const cb = self.chequebook orelse {
            std.debug.print(
                "[swap] {s}: charge tripped ({d} chunks) but no --chequebook; bee will disconnect when threshold hits\n",
                .{ std.fmt.bytesToHex(conn.peer_overlay, .lower), accounting_mod.TRIGGER_CHUNKS },
            );
            return;
        };

        // Open the swap stream and negotiate headers FIRST. We need
        // exchange_rate and deduction to size the cheque correctly: bee's
        // accounting is denominated in base units, the cheque payout in
        // BZZ wei, and the conversion (credited_base_units = (payout -
        // deduction) / exchange_rate) is peer-announced. Building the
        // cheque before negotiation would force a hardcoded wei amount
        // that silently scales inversely with whatever rate the peer
        // announces — see the 2026-04-29 live test where a 20 M wei
        // cheque against exchange=100 k credited only 199 base units
        // versus a 1.35 M base-unit threshold.
        const stream = try conn.openStream();
        defer stream.close() catch {};

        try multistream.selectOne(stream, swap_mod.PROTOCOL_ID);
        const headers = try swap_mod.negotiate(self.allocator, stream);

        // delta_wei = exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction.
        // CREDIT_TARGET_BASE_UNITS is set high enough (10 M) to clear any
        // plausible peer-announced threshold by ~7×; see accounting.zig
        // for the rationale.
        const delta_wei: u256 =
            headers.exchange_rate * @as(u256, accounting_mod.CREDIT_TARGET_BASE_UNITS) +
            headers.deduction;

        // Build + sign now that we know the right size. The build call
        // persists the new cumulative atomically *before* returning, so a
        // crash between build and send won't issue a stale (re-decreasing)
        // cumulative on retry.
        const c = try acc.buildCheque(conn.peer_overlay, cb.contract, conn.peer_eth_address, delta_wei);
        const sig = try cheque_mod.sign(&c, cb.chain_id, cb.owner_private_key);
        const signed = cheque_mod.SignedCheque{ .cheque = c, .signature = sig };

        std.debug.print(
            "[swap] {s}: negotiated exchange={d} deduction={d}; emitting cheque cumulativePayout={d} (delta={d})\n",
            .{
                std.fmt.bytesToHex(conn.peer_overlay, .lower),
                headers.exchange_rate,
                headers.deduction,
                c.cumulative_payout,
                delta_wei,
            },
        );

        try swap_mod.sendCheque(self.allocator, stream, &signed);
        acc.markChequeSent(conn.peer_overlay);
        std.debug.print(
            "[swap] {s}: cheque accepted by stream layer; chunk counter reset\n",
            .{std.fmt.bytesToHex(conn.peer_overlay, .lower)},
        );
    }

    // --------------------------------------------------------------------
    // One-shot helpers used by the legacy CLI (no daemon).
    // --------------------------------------------------------------------

    /// Dials a single peer, runs the optional post-handshake action, and
    /// either returns immediately (action ≠ .none) or stays in the accept
    /// loop forever (action == .none).
    pub fn dial(self: *P2PNode, ip: []const u8, port: u16, action: PostHandshakeAction) !void {
        const ip4 = parseIpv4(ip) orelse return error.InvalidIp;

        std.debug.print("Dialing {s}:{d} (network_id={d})\n", .{ ip, port, self.network_id });
        const conn = try Connection.dial(
            self.allocator,
            &self.id,
            self.network_id,
            self.nonce,
            ip4,
            port,
        );
        std.debug.print(
            "[bee-hs-out] handshake done: peer overlay={s} network={d} full_node={any}\n",
            .{ std.fmt.bytesToHex(conn.peer_overlay, .lower), self.network_id, conn.peer_full_node },
        );
        if (conn.peer_welcome_message.len > 0) {
            std.debug.print("[bee-hs-out] welcome: \"{s}\"\n", .{conn.peer_welcome_message});
        }

        try self.registerConnection(conn);

        switch (action) {
            .retrieve => |r| {
                runRetrievalAgainst(conn, self.allocator, r.address, r.key, r.out_path) catch |e| {
                    std.debug.print("[retrieve] failed: {any}\n", .{e});
                };
                return;
            },
            .none => {
                // Idle: park here while inbound streams are processed by
                // conn.accept_thread. Sleep on a flag.
                while (true) std.Thread.sleep(60 * std.time.ns_per_s);
            },
        }
    }

    // --------------------------------------------------------------------
    // Daemon mode.
    // --------------------------------------------------------------------

    pub const DaemonOpts = struct {
        bootnode_ip: []const u8,
        bootnode_port: u16,
        max_peers: usize = 4,
        api_port: u16 = 9090,
    };

    /// Daemon: dial bootnode → as hive entries arrive, dial up to
    /// max_peers from them → serve an HTTP API for retrieval.
    /// Returns cleanly on SIGINT/SIGTERM after joining the dialer worker.
    pub fn daemonRun(self: *P2PNode, opts: DaemonOpts) !void {
        try installSignalHandlers();

        const ip4 = parseIpv4(opts.bootnode_ip) orelse return error.InvalidIp;
        std.debug.print("[daemon] dialing bootnode {s}:{d} (network_id={d})\n", .{ opts.bootnode_ip, opts.bootnode_port, self.network_id });
        const boot_conn = try Connection.dial(
            self.allocator,
            &self.id,
            self.network_id,
            self.nonce,
            ip4,
            opts.bootnode_port,
        );
        std.debug.print(
            "[daemon] bootnode handshake done: overlay={s} welcome=\"{s}\"\n",
            .{ std.fmt.bytesToHex(boot_conn.peer_overlay, .lower), boot_conn.peer_welcome_message },
        );
        try self.registerConnection(boot_conn);

        // Worker that drains the hive-candidate queue and tries to dial
        // each candidate up to `max_peers`. Joinable (not detached) so
        // graceful shutdown can wait for it to finish its current iteration.
        const dialer_ctx = try self.allocator.create(DialerCtx);
        defer self.allocator.destroy(dialer_ctx);
        dialer_ctx.* = .{ .node = self, .max_peers = opts.max_peers };
        const dialer_thread = try std.Thread.spawn(.{}, runHiveDialer, .{dialer_ctx});

        // HTTP API. Polls `g_shutdown` and returns cleanly when the
        // signal handler raises it.
        serveApi(self, opts.api_port) catch |e| {
            std.debug.print("[daemon] serveApi exited: {any}\n", .{e});
        };

        // Shutdown raised: dialer's next loop iteration will exit (it
        // checks g_shutdown before sleeping). Join it before returning
        // so main's `defer node.deinit()` can tear down connections
        // with no thread still poking at them.
        std.debug.print("[daemon] shutting down — waiting for dialer to exit\n", .{});
        dialer_thread.join();
        std.debug.print("[daemon] dialer joined; closing connections\n", .{});
    }
};

// ---- per-attempt retrieval with a 30 s watchdog ----
//
// Semantics:
//   * The watchdog runs on a dedicated thread for each retrieval attempt.
//     It uses a Condition + timedWait so the happy path wakes immediately
//     after the retrieval returns; only a hung peer eats the full 30 s.
//   * On timeout, the watchdog calls `stream.cancel()` (yamux RST + signal
//     waiters), so the in-flight read in `retrieval.request` unblocks with
//     `error.StreamReset`.
//   * The timeout matches bee's `RetrieveChunkTimeout = 30 * time.Second`
//     in `pkg/retrieval/retrieval.go`.

const Watchdog = struct {
    mtx: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    fired: bool = false,
    stream: *yamux.Stream,
    timeout_ns: u64,

    fn run(self: *Watchdog) void {
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.done) return;
        self.cond.timedWait(&self.mtx, self.timeout_ns) catch {
            // timedWait returned error.Timeout: the retrieval hasn't
            // finished. Force the stream down.
            if (!self.done) {
                self.fired = true;
                self.stream.cancel();
            }
        };
    }

    fn signalDone(self: *Watchdog) void {
        self.mtx.lock();
        self.done = true;
        self.mtx.unlock();
        self.cond.signal();
    }
};

fn tryRetrieveOnceWithTimeout(
    allocator: std.mem.Allocator,
    conn: *Connection,
    addr: [bmt.HASH_SIZE]u8,
    timeout_ns: u64,
) !retrieval.RetrievedChunk {
    const yamux_stream = try conn.openStream();
    defer yamux_stream.close() catch {};

    var wd = Watchdog{ .stream = yamux_stream, .timeout_ns = timeout_ns };
    const wd_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});
    defer wd_thread.join();
    defer wd.signalDone();

    try multistream.selectOne(yamux_stream, retrieval.PROTOCOL_ID);
    return retrieval.request(allocator, yamux_stream, addr);
}

// ---- one-shot retrieval against a specific connection ----

fn runRetrievalAgainst(
    conn: *Connection,
    allocator: std.mem.Allocator,
    chunk_address: [bmt.HASH_SIZE]u8,
    chunk_key: ?[encryption.KEY_LEN]u8,
    out_path: ?[]const u8,
) !void {
    std.debug.print(
        "[retrieve] requesting chunk {s}{s} via peer {s}\n",
        .{
            std.fmt.bytesToHex(chunk_address, .lower),
            if (chunk_key != null) " (encrypted)" else "",
            std.fmt.bytesToHex(conn.peer_overlay, .lower),
        },
    );
    const stream = try conn.openStream();
    defer stream.close() catch {};

    multistream.selectOne(stream, retrieval.PROTOCOL_ID) catch |e| {
        std.debug.print("[retrieve] multistream-select failed: {any}\n", .{e});
        return e;
    };

    var rc = retrieval.request(allocator, stream, chunk_address) catch |e| {
        std.debug.print("[retrieve] request failed: {any}\n", .{e});
        return e;
    };
    defer rc.deinit();

    std.debug.print(
        "[retrieve] got {d} bytes (span={d})\n",
        .{ rc.data.len, rc.span },
    );

    // For encrypted single-chunk retrieval we need to feed
    // decryptChunk the wire-format chunk (span(8 LE) ‖ payload).
    // retrieval.request returns the payload separately, so reconstruct.
    var owned_plain: ?[]u8 = null;
    defer if (owned_plain) |p| allocator.free(p);
    const data_to_write: []const u8 = if (chunk_key) |k| blk: {
        const wire = try allocator.alloc(u8, 8 + rc.data.len);
        defer allocator.free(wire);
        std.mem.writeInt(u64, wire[0..8], rc.span, .little);
        @memcpy(wire[8..], rc.data);
        const plain = encryption.decryptChunk(allocator, k, wire) catch |e| {
            std.debug.print("[retrieve] decrypt failed: {any}\n", .{e});
            return e;
        };
        owned_plain = plain;
        // decryptChunk returns span(8) ‖ payload — strip the span for output.
        break :blk plain[8..];
    } else rc.data;

    if (out_path) |p| {
        const f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll(data_to_write);
        std.debug.print("[retrieve] wrote {d} bytes to {s}\n", .{ data_to_write.len, p });
    } else {
        std.debug.print("[retrieve] data (hex): ", .{});
        for (data_to_write) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});
    }
}

// ---- dispatcher for inbound streams (called from each Connection's accept loop) ----

fn dispatchInboundStream(ctx_opaque: *anyopaque, conn: *Connection, s: *yamux.Stream) void {
    const self: *P2PNode = @ptrCast(@alignCast(ctx_opaque));
    handleInboundStream(self, conn, s) catch |e| {
        std.debug.print("[host] stream {d}: handler errored: {any}\n", .{ s.id, e });
    };
}

fn handleInboundStream(self: *P2PNode, conn: *Connection, s: *yamux.Stream) !void {
    _ = conn; // unused for now; protocol handlers don't need per-conn state
    var buf: [256]u8 = undefined;

    const hello = multistream.readMessage(s, &buf) catch |e| {
        std.debug.print("[host] stream {d}: read hello failed: {any}\n", .{ s.id, e });
        return;
    };
    if (!std.mem.eql(u8, hello, multistream.VERSION)) {
        std.debug.print("[host] stream {d}: expected multistream hello, got \"{s}\"\n", .{ s.id, hello });
        return;
    }

    var wrote_our_hello = false;
    while (true) {
        const proposal = multistream.readMessage(s, &buf) catch |e| {
            std.debug.print("[host] stream {d}: read proposal failed: {any}\n", .{ s.id, e });
            return;
        };
        if (!wrote_our_hello) {
            multistream.writeMessage(s, multistream.VERSION) catch return;
            wrote_our_hello = true;
        }
        if (std.mem.eql(u8, proposal, identify.PROTOCOL_ID)) {
            std.debug.print("[host] stream {d}: serving {s}\n", .{ s.id, identify.PROTOCOL_ID });
            identify.respond(s, &self.id, &SUPPORTED_PROTOCOLS) catch |e| {
                std.debug.print("[host] stream {d}: identify respond failed: {any}\n", .{ s.id, e });
            };
            return;
        }
        if (std.mem.eql(u8, proposal, ping.PROTOCOL_ID)) {
            std.debug.print("[host] stream {d}: serving {s}\n", .{ s.id, ping.PROTOCOL_ID });
            ping.respond(s) catch |e| {
                std.debug.print("[host] stream {d}: ping respond ended: {any}\n", .{ s.id, e });
            };
            return;
        }
        if (std.mem.eql(u8, proposal, pricing.PROTOCOL_ID)) {
            std.debug.print("[host] stream {d}: serving {s}\n", .{ s.id, pricing.PROTOCOL_ID });
            multistream.writeMessage(s, pricing.PROTOCOL_ID) catch return;
            pricing.respond(self.allocator, s) catch |e| {
                std.debug.print("[pricing] respond ended: {any}\n", .{e});
            };
            s.close() catch {};
            return;
        }
        if (std.mem.eql(u8, proposal, hive.PROTOCOL_ID)) {
            std.debug.print("[host] stream {d}: serving {s}\n", .{ s.id, hive.PROTOCOL_ID });
            multistream.writeMessage(s, hive.PROTOCOL_ID) catch return;
            self.peersLock();
            const before = self.peers.count();
            hive.respond(self.allocator, s, &self.peers, self.network_id) catch |e| {
                std.debug.print("[hive] respond ended: {any}\n", .{e});
            };
            const after = self.peers.count();
            self.peersUnlock();
            if (after > before) {
                // We don't have a callback list of newly-added overlays
                // from hive yet; iterate the peer table and let the
                // dialer decide which are worth dialing.
                queueAllPeersAsCandidates(self) catch {};
            }
            s.close() catch {};
            return;
        }
        std.debug.print("[host] stream {d}: rejecting unsupported \"{s}\"\n", .{ s.id, proposal });
        multistream.writeMessage(s, multistream.NA) catch return;
    }
}

fn queueAllPeersAsCandidates(self: *P2PNode) !void {
    self.peersLock();
    defer self.peersUnlock();
    var it = self.peers.peers.iterator();
    while (it.next()) |entry| {
        try self.enqueueHiveCandidate(entry.key_ptr.*);
    }
}

// ---- daemon: hive-driven auto-dialer ----

const DialerCtx = struct {
    node: *P2PNode,
    max_peers: usize,
};

/// Per-peer dial-attempt bookkeeping. We retry with backoff so a transient
/// failure (peer flapped, bootnode hadn't propagated yet, etc.) doesn't
/// permanently drop a candidate from rotation.
const AttemptState = struct {
    attempts: u8 = 0,
    last_ns: i128 = 0,
};

const MAX_ATTEMPTS_PER_PEER: u8 = 5;
const BACKOFF_BASE_NS: i128 = 15 * std.time.ns_per_s;
const MANAGE_TICK_NS: u64 = 15 * std.time.ns_per_s;

fn runHiveDialer(ctx: *DialerCtx) void {
    runHiveDialerInner(ctx) catch |e| {
        std.debug.print("[dialer] worker exited: {any}\n", .{e});
    };
}

fn runHiveDialerInner(ctx: *DialerCtx) !void {
    var state_map = std.AutoHashMap([bzz_address.OVERLAY_LEN]u8, AttemptState).init(ctx.node.allocator);
    defer state_map.deinit();

    var last_manage_tick: i128 = 0;

    while (true) {
        if (g_shutdown.load(.acquire)) return;

        // Manage tick — runs FIRST, before the connectionCount gate,
        // because dead connections inflate the count and would
        // otherwise prevent the prune from ever firing.
        // Two housekeeping jobs every MANAGE_TICK_NS:
        //   1. Reap connections whose accept thread has exited (peer
        //      disconnected, accounting kicked us, TCP reset, …).
        //      Frees the underlying TCP+Noise+Yamux structs.
        //   2. Re-queue every still-unconnected peer in the table so
        //      a quiet hive doesn't leave us stranded with candidates
        //      we never got around to trying. Bee's discovery does
        //      the analogous thing in its kademlia manage loop.
        const now = std.time.nanoTimestamp();
        if (now - last_manage_tick > @as(i128, MANAGE_TICK_NS)) {
            last_manage_tick = now;
            ctx.node.pruneDeadConnections() catch {};
            requeueUnconnectedPeers(ctx.node) catch {};
        }

        // After the manage tick: if we already have enough live
        // connections, idle until next tick. (`connectionCount`
        // filters dead connections, so the prune above will have
        // brought the count down if there were any dead.)
        if (ctx.node.connectionCount() >= ctx.max_peers) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        }

        const candidate = ctx.node.dequeueHiveCandidate() orelse {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };

        if (ctx.node.isConnectedToOverlay(candidate)) continue;

        const gop = try state_map.getOrPut(candidate);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const st = gop.value_ptr;

        if (st.attempts >= MAX_ATTEMPTS_PER_PEER) continue;
        // Exponential-ish backoff: 0s, 15s, 30s, 60s, 120s.
        const min_wait_ns: i128 = if (st.attempts == 0)
            0
        else
            BACKOFF_BASE_NS * (@as(i128, 1) << @intCast(st.attempts - 1));
        if (st.last_ns != 0 and (now - st.last_ns) < min_wait_ns) continue;

        // Look up the candidate in the peer table; bee may ship multiple
        // multiaddrs per peer (0x99-prefixed list) — walk them and pick the
        // first public IPv4+TCP entry. Private CIDRs are bootnode-internal
        // (k8s pods) and not reachable from outside.
        const entry = ctx.node.peers.get(candidate) orelse continue;
        const ipt_opt = pickReachableIp4Tcp(ctx.node.allocator, entry.underlay);
        const ipt = ipt_opt orelse {
            // No public IP — record a "soft" attempt so we don't spin on it.
            st.attempts += 1;
            st.last_ns = now;
            continue;
        };

        st.attempts += 1;
        st.last_ns = now;

        std.debug.print(
            "[dialer] dialing candidate {s} at {d}.{d}.{d}.{d}:{d} (attempt {d}/{d})\n",
            .{
                std.fmt.bytesToHex(candidate, .lower),
                ipt.ip[0], ipt.ip[1], ipt.ip[2], ipt.ip[3],
                ipt.port,
                st.attempts, MAX_ATTEMPTS_PER_PEER,
            },
        );
        const conn = Connection.dial(
            ctx.node.allocator,
            &ctx.node.id,
            ctx.node.network_id,
            ctx.node.nonce,
            ipt.ip,
            ipt.port,
        ) catch |e| {
            std.debug.print("[dialer] dial failed for {d}.{d}.{d}.{d}:{d}: {any}\n", .{
                ipt.ip[0], ipt.ip[1], ipt.ip[2], ipt.ip[3], ipt.port, e,
            });
            continue;
        };

        std.debug.print(
            "[dialer] connected #{d}/{d}: overlay={s}\n",
            .{
                ctx.node.connectionCount() + 1,
                ctx.max_peers,
                std.fmt.bytesToHex(conn.peer_overlay, .lower),
            },
        );
        ctx.node.registerConnection(conn) catch |e| {
            std.debug.print("[dialer] registerConnection failed: {any}\n", .{e});
            conn.deinit();
            continue;
        };
    }
}

fn requeueUnconnectedPeers(node: *P2PNode) !void {
    node.peersLock();
    defer node.peersUnlock();
    var it = node.peers.peers.iterator();
    while (it.next()) |entry| {
        const ov = entry.key_ptr.*;
        if (node.isConnectedToOverlay(ov)) continue;
        try node.enqueueHiveCandidate(ov);
    }
}

/// Walks an underlay payload (legacy or 0x99-list) and returns the first
/// public IPv4+TCP endpoint. null if every entry is private/non-IPv4.
fn pickReachableIp4Tcp(
    allocator: std.mem.Allocator,
    underlay: []const u8,
) ?struct { ip: [4]u8, port: u16 } {
    var it = bzz_address.UnderlayIterator.init(underlay);
    while (true) {
        const ma_bytes = (it.next() catch return null) orelse return null;
        const ma = multiaddr.Multiaddr.fromBytesBorrow(allocator, ma_bytes);
        const ipt = ma.ip4Tcp() orelse continue;
        if (isPrivateOrLoopback(ipt.ip)) continue;
        return .{ .ip = ipt.ip, .port = ipt.port };
    }
}

fn isPrivateOrLoopback(ip: [4]u8) bool {
    if (ip[0] == 127) return true; // 127.0.0.0/8
    if (ip[0] == 10) return true; // 10.0.0.0/8
    if (ip[0] == 192 and ip[1] == 168) return true; // 192.168.0.0/16
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return true; // 172.16/12
    if (ip[0] == 169 and ip[1] == 254) return true; // link-local
    if (ip[0] == 0) return true; // 0.0.0.0/8
    return false;
}

// ---- HTTP API ----

fn serveApi(node: *P2PNode, port: u16) !void {
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    std.debug.print("[api] listening on 127.0.0.1:{d}\n", .{port});

    // Poll the listener with a 200 ms timeout so we re-check the shutdown
    // flag at most ~5x per second. accept() itself stays blocking — poll
    // gates whether we call it. SIGINT/SIGTERM also interrupts the poll
    // syscall directly with EINTR; we treat that as "go re-check shutdown".
    var pfds = [_]std.posix.pollfd{.{
        .fd = server.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (!g_shutdown.load(.acquire)) {
        // Zig's std.posix.poll wraps EINTR internally; we don't see
        // SignalInterrupt here. Any other error is logged and we just
        // re-loop (which re-checks the shutdown flag).
        const ready = std.posix.poll(&pfds, 200) catch |e| {
            std.debug.print("[api] poll failed: {any}\n", .{e});
            continue;
        };
        if (ready == 0) continue; // timeout — loop back to shutdown check

        const conn = server.accept() catch |e| {
            std.debug.print("[api] accept failed: {any}\n", .{e});
            continue;
        };
        // Each request runs on its own thread.
        const ctx = node.allocator.create(ApiCtx) catch {
            conn.stream.close();
            continue;
        };
        ctx.* = .{ .node = node, .stream = conn.stream };
        const t = std.Thread.spawn(.{}, handleApi, .{ctx}) catch {
            conn.stream.close();
            node.allocator.destroy(ctx);
            continue;
        };
        t.detach();
    }
    std.debug.print("[api] shutdown — stopped accepting connections\n", .{});
}

const ApiCtx = struct {
    node: *P2PNode,
    stream: net.Stream,
};

// HTTP API surface. All read-only GET endpoints. The bee-compatible ones
// are listed first; field names + JSON shape match bee's REST handlers
// in pkg/api/{health,node,p2p,peer,topology,chunk,bytes,bzz}.go so
// existing bee tools (curl scripts, dashboards, the bee CLI) can point
// at zigbee for read-only retrieval and still work.
//
//   GET /health                     bee-shape — service liveness probe
//   GET /readiness                  bee-shape — readiness probe (alias)
//   GET /node                       bee-shape — beeMode (we report "ultra-light"),
//                                   chequebookEnabled = false, swapEnabled = false
//   GET /addresses                  bee-shape — overlay, chain_address, ethereum,
//                                   publicKey, pssPublicKey, underlay
//   GET /peers                      bee-shape — connected peers (overlay + fullNode)
//   GET /topology                   bee-shape-ish — Kademlia bin populations
//   GET /chunks/<addr>              bee-shape — raw chunk = span(8) ‖ payload,
//                                   content-type binary/octet-stream
//   GET /bytes/<ref>                bee-shape — file via joiner, no manifest
//                                   walk; treats <ref> as a CAC tree root
//   GET /bzz/<ref>                  bee-shape — file via joiner, manifest-aware
//                                   (resolves website-index-document)
//   GET /bzz/<ref>/<path>           bee-shape — manifest path lookup (mantaray)
//   POST /pingpong/<peer-overlay>   bee-shape — initiate libp2p Ping against
//                                   an already-connected peer; returns
//                                   {"rtt":"<duration>"}
//
// Plus zigbee-native legacy aliases:
//
//   GET /retrieve/<hex>             single chunk, payload only, X-Chunk-Span
//                                   header (the original 0.1 endpoint, kept
//                                   for back-compat with existing scripts)

fn handleApi(ctx: *ApiCtx) void {
    defer ctx.stream.close();
    defer ctx.node.allocator.destroy(ctx);

    var req_buf: [4096]u8 = undefined;
    const n = ctx.stream.read(&req_buf) catch return;
    if (n == 0) return;
    const req = req_buf[0..n];

    const line_end = std.mem.indexOfScalar(u8, req, '\r') orelse return;
    const line = req[0..line_end];

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const path = it.next() orelse return;

    if (std.mem.eql(u8, method, "GET")) {
        routeGet(ctx.node, ctx.stream, path) catch |e| {
            std.debug.print("[api] {s} → handler errored: {any}\n", .{ path, e });
        };
        return;
    }
    if (std.mem.eql(u8, method, "POST")) {
        routePost(ctx.node, ctx.stream, path) catch |e| {
            std.debug.print("[api] POST {s} → handler errored: {any}\n", .{ path, e });
        };
        return;
    }
    writeHttp(ctx.stream, 405, "text/plain", "method not allowed\n") catch {};
}

fn routePost(node: *P2PNode, stream: net.Stream, path: []const u8) !void {
    if (std.mem.startsWith(u8, path, "/pingpong/")) {
        const hex = path[10..];
        const overlay = parseHexAddress(stream, hex) orelse return;
        return handlePingpongApi(node, stream, overlay);
    }
    try writeHttp(stream, 404, "text/plain", "unknown path\n");
}

fn routeGet(node: *P2PNode, stream: net.Stream, path: []const u8) !void {
    // Bee-compatible identity / health
    if (std.mem.eql(u8, path, "/health")) return handleHealth(node, stream);
    if (std.mem.eql(u8, path, "/readiness")) return handleHealth(node, stream);
    if (std.mem.eql(u8, path, "/node")) return handleNode(node, stream);
    if (std.mem.eql(u8, path, "/addresses")) return handleAddresses(node, stream);
    if (std.mem.eql(u8, path, "/peers")) return handlePeersBee(node, stream);
    if (std.mem.eql(u8, path, "/topology")) return handleTopology(node, stream);

    // Bee-compatible storage
    if (std.mem.startsWith(u8, path, "/chunks/")) {
        const hex = path[8..];
        const addr = parseHexAddress(stream, hex) orelse return;
        return handleChunkBee(node, stream, addr);
    }
    if (std.mem.startsWith(u8, path, "/bytes/")) {
        const hex = path[7..];
        const ref = parseHexRef(stream, hex) orelse return;
        return handleBytes(node, stream, ref);
    }
    if (std.mem.startsWith(u8, path, "/bzz/")) {
        // /bzz/<64-hex>            — unencrypted, default file
        // /bzz/<128-hex>           — encrypted (32 addr ‖ 32 key), default file
        // /bzz/<64|128-hex>/<path> — manifest path lookup
        const rest = path[5..];
        const ref_hex_len: usize = if (rest.len >= 128 and (rest.len == 128 or rest[128] == '/'))
            128
        else if (rest.len >= 64 and (rest.len == 64 or rest[64] == '/'))
            64
        else
            0;
        if (ref_hex_len == 0) {
            try writeHttp(stream, 400, "text/plain", "reference must be 64 (CAC) or 128 (encrypted) hex chars\n");
            return;
        }
        const ref = parseHexRef(stream, rest[0..ref_hex_len]) orelse return;
        const after = rest[ref_hex_len..];
        const inner_path = if (after.len == 0 or std.mem.eql(u8, after, "/"))
            ""
        else if (after[0] == '/')
            after[1..]
        else {
            try writeHttp(stream, 400, "text/plain", "expected '/<path>' after reference\n");
            return;
        };
        return handleBzzApi(node, stream, ref, inner_path);
    }

    // Zigbee-native legacy alias
    if (std.mem.startsWith(u8, path, "/retrieve/")) {
        const hex = path[10..];
        const ref = parseHexRef(stream, hex) orelse return;
        return handleRetrieveApi(node, stream, ref);
    }

    try writeHttp(stream, 404, "text/plain", "unknown path\n");
}

/// A Swarm reference. 32-byte addr always; 32-byte symmetric key only
/// when the ref came from an encrypted upload (`Swarm-Encrypt: true`).
pub const Ref = struct {
    addr: [bmt.HASH_SIZE]u8,
    key: ?[encryption.KEY_LEN]u8 = null,

    pub fn isEncrypted(self: Ref) bool {
        return self.key != null;
    }
};

/// Parse a 64-char (CAC) or 128-char (encrypted, addr ‖ key) hex
/// reference. Writes the HTTP error response and returns null on failure.
fn parseHexRef(stream: net.Stream, hex: []const u8) ?Ref {
    if (hex.len == 64) {
        var addr: [bmt.HASH_SIZE]u8 = undefined;
        _ = std.fmt.hexToBytes(&addr, hex) catch {
            writeHttp(stream, 400, "text/plain", "invalid hex\n") catch {};
            return null;
        };
        return .{ .addr = addr };
    }
    if (hex.len == 128) {
        var raw: [encryption.REFERENCE_SIZE]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, hex) catch {
            writeHttp(stream, 400, "text/plain", "invalid hex\n") catch {};
            return null;
        };
        var addr: [bmt.HASH_SIZE]u8 = undefined;
        var key: [encryption.KEY_LEN]u8 = undefined;
        @memcpy(&addr, raw[0..bmt.HASH_SIZE]);
        @memcpy(&key, raw[bmt.HASH_SIZE..]);
        return .{ .addr = addr, .key = key };
    }
    writeHttp(stream, 400, "text/plain", "reference must be 64 (CAC) or 128 (encrypted) hex chars\n") catch {};
    return null;
}

/// 32-byte-only variant for endpoints that take a chunk address rather
/// than a file reference (`/chunks/<addr>` and `POST /pingpong/<peer>`).
fn parseHexAddress(stream: net.Stream, hex: []const u8) ?[bmt.HASH_SIZE]u8 {
    if (hex.len != 64) {
        writeHttp(stream, 400, "text/plain", "address must be 64 hex chars\n") catch {};
        return null;
    }
    var addr: [bmt.HASH_SIZE]u8 = undefined;
    _ = std.fmt.hexToBytes(&addr, hex) catch {
        writeHttp(stream, 400, "text/plain", "invalid hex\n") catch {};
        return null;
    };
    return addr;
}

fn handleRetrieveApi(
    node: *P2PNode,
    stream: net.Stream,
    ref: Ref,
) !void {
    var rc = node.retrieveChunkIterating(ref.addr) catch |e| {
        try writeHttpFmt(
            stream,
            if (e == error.NoConnectedPeers) @as(u16, 503) else @as(u16, 502),
            "text/plain",
            "retrieval failed: {any}\n",
            .{e},
        );
        return;
    };
    defer rc.deinit();

    // Decrypt for encrypted refs. The retrieval module returned the
    // ciphertext (BMT was validated against the encrypted bytes, which
    // is what bee hashes for the on-wire address). The legacy
    // `/retrieve/<hex>` endpoint exposes the raw single-chunk bytes
    // without the 8-byte span; for encrypted refs we hand back the
    // *decrypted* payload trimmed to the real span.
    if (ref.key) |k| {
        // Re-serialize span(8) ‖ data so encryption.decryptChunk can do
        // its trim-to-real-span work in one place.
        const wire = try node.allocator.alloc(u8, bmt.SPAN_SIZE + rc.data.len);
        defer node.allocator.free(wire);
        std.mem.writeInt(u64, wire[0..bmt.SPAN_SIZE], rc.span, .little);
        @memcpy(wire[bmt.SPAN_SIZE..], rc.data);

        const decrypted = encryption.decryptChunk(node.allocator, k, wire) catch |e| {
            try writeHttpFmt(stream, 502, "text/plain", "decrypt failed: {any}\n", .{e});
            return;
        };
        defer node.allocator.free(decrypted);

        const decrypted_span = std.mem.readInt(u64, decrypted[0..bmt.SPAN_SIZE], .little);
        const payload = decrypted[bmt.SPAN_SIZE..];

        var hdr_buf: [256]u8 = undefined;
        const hdr = try std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Chunk-Span: {d}\r\n\r\n",
            .{ payload.len, decrypted_span },
        );
        try stream.writeAll(hdr);
        try stream.writeAll(payload);
        return;
    }

    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Chunk-Span: {d}\r\n\r\n",
        .{ rc.data.len, rc.span },
    );
    try stream.writeAll(hdr);
    try stream.writeAll(rc.data);
}

/// `POST /pingpong/<peer-overlay>` — bee shape (`pkg/api/pingpong.go`).
/// Looks up an *already-connected* peer by overlay, opens a yamux stream,
/// runs `/ipfs/ping/1.0.0` once, returns `{"rtt":"<duration>"}` with the
/// duration string formatted like Go's `time.Duration.String()`.
/// Returns 404 if the peer is not in our connection list (matches bee's
/// `p2p.ErrPeerNotFound` → `jsonhttp.NotFound("peer not found")`).
fn handlePingpongApi(
    node: *P2PNode,
    http_stream: net.Stream,
    overlay: [bzz_address.OVERLAY_LEN]u8,
) !void {
    // Find the live connection. Reproduces the same dead-conn filter used
    // by closestConnectionTo / connectionsSortedByDistance / handlePeersBee.
    var conn: ?*Connection = null;
    node.connections_mtx.lock();
    for (node.connections.items) |c| {
        if (c.isDead()) continue;
        if (std.mem.eql(u8, &c.peer_overlay, &overlay)) {
            conn = c;
            break;
        }
    }
    node.connections_mtx.unlock();

    if (conn == null) {
        try writeJson(http_stream, 404,
            \\{"code":404,"message":"peer not found"}
        );
        return;
    }

    const ystream = conn.?.openStream() catch |e| {
        try writeHttpFmt(http_stream, 500, "application/json", "{{\"code\":500,\"message\":\"openStream failed: {any}\"}}", .{e});
        return;
    };
    defer ystream.close() catch {};

    const rtt_ns = ping.ping(ystream) catch |e| {
        try writeHttpFmt(http_stream, 500, "application/json", "{{\"code\":500,\"message\":\"pingpong failed: {any}\"}}", .{e});
        return;
    };

    var rtt_buf: [32]u8 = undefined;
    const rtt_str = formatGoDuration(&rtt_buf, rtt_ns);

    var body_buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"rtt\":\"{s}\"}}", .{rtt_str});
    try writeJson(http_stream, 200, body);
}

/// Format a duration in nanoseconds the way Go's `time.Duration.String()`
/// does for the units we'll see from a libp2p ping (≥ 1 ns, almost always
/// 100µs–500ms in practice). Picks the largest unit such that the integer
/// part is ≥ 1 and prints up to 3 fractional digits without trailing zeros.
/// Examples: 1234567 → "1.234ms", 5678 → "5.678µs", 12000000000 → "12s".
fn formatGoDuration(out: []u8, ns: u64) []const u8 {
    if (ns == 0) return std.fmt.bufPrint(out, "0s", .{}) catch unreachable;

    // Pick unit. Go falls through h/m/s for ≥ 1s, otherwise ms / µs / ns.
    if (ns >= std.time.ns_per_s) {
        const whole = ns / std.time.ns_per_s;
        const frac_ms = (ns % std.time.ns_per_s) / std.time.ns_per_ms; // 0..999
        if (frac_ms == 0) return std.fmt.bufPrint(out, "{d}s", .{whole}) catch unreachable;
        return std.fmt.bufPrint(out, "{d}.{d:0>3}s", .{ whole, frac_ms }) catch unreachable;
    }
    if (ns >= std.time.ns_per_ms) {
        const whole = ns / std.time.ns_per_ms;
        const frac_us = (ns % std.time.ns_per_ms) / std.time.ns_per_us; // 0..999
        if (frac_us == 0) return std.fmt.bufPrint(out, "{d}ms", .{whole}) catch unreachable;
        return std.fmt.bufPrint(out, "{d}.{d:0>3}ms", .{ whole, frac_us }) catch unreachable;
    }
    if (ns >= std.time.ns_per_us) {
        const whole = ns / std.time.ns_per_us;
        const frac_ns = ns % std.time.ns_per_us; // 0..999
        if (frac_ns == 0) return std.fmt.bufPrint(out, "{d}µs", .{whole}) catch unreachable;
        return std.fmt.bufPrint(out, "{d}.{d:0>3}µs", .{ whole, frac_ns }) catch unreachable;
    }
    return std.fmt.bufPrint(out, "{d}ns", .{ns}) catch unreachable;
}

test "formatGoDuration: matches Go's time.Duration.String() shape" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatGoDuration(&buf, 0));
    try std.testing.expectEqualStrings("123ns", formatGoDuration(&buf, 123));
    try std.testing.expectEqualStrings("5µs", formatGoDuration(&buf, 5_000));
    try std.testing.expectEqualStrings("5.678µs", formatGoDuration(&buf, 5_678));
    try std.testing.expectEqualStrings("1ms", formatGoDuration(&buf, 1_000_000));
    try std.testing.expectEqualStrings("1.234ms", formatGoDuration(&buf, 1_234_000));
    try std.testing.expectEqualStrings("12s", formatGoDuration(&buf, 12_000_000_000));
    try std.testing.expectEqualStrings("12.500s", formatGoDuration(&buf, 12_500_000_000));
}

// ---- /bzz: full-file (chunk-tree) retrieval ----
//
// Adapter that turns `P2PNode.retrieveChunkIterating` into the joiner's
// `FetchFn` shape. The joiner asks for raw chunk bytes (`span ‖ payload`),
// while our retrieval API hands us span and payload separately, so we
// rebuild the 8-byte span prefix here.

fn joinerFetchAdapter(
    ctx: *anyopaque,
    addr: [bmt.HASH_SIZE]u8,
    out: *[]u8,
) anyerror!void {
    const node: *P2PNode = @ptrCast(@alignCast(ctx));
    var rc = try node.retrieveChunkIterating(addr);
    defer rc.deinit();
    const buf = try node.allocator.alloc(u8, bmt.SPAN_SIZE + rc.data.len);
    std.mem.writeInt(u64, buf[0..bmt.SPAN_SIZE], rc.span, .little);
    @memcpy(buf[bmt.SPAN_SIZE..], rc.data);
    out.* = buf;
}

fn handleBzzApi(
    node: *P2PNode,
    stream: net.Stream,
    ref: Ref,
    /// Optional manifest path. Empty string ⇒ resolve the manifest's
    /// default file (bee's `website-index-document` flow). Non-empty ⇒
    /// look the path up in the trie and serve that entry.
    inner_path: []const u8,
) !void {
    std.debug.print(
        "[api] /bzz {s}{s}{s}{s}\n",
        .{
            std.fmt.bytesToHex(ref.addr, .lower),
            if (ref.key != null) "...(encrypted)" else "",
            if (inner_path.len > 0) "/" else "",
            inner_path,
        },
    );

    // Step 1: fetch the root chunk via origin-retry iteration. For
    // encrypted refs, decrypt before looking at the manifest signature
    // (the on-wire bytes are ciphertext; mantaray.looksLikeManifest
    // expects the plaintext header).
    var rc = node.retrieveChunkIterating(ref.addr) catch |e| {
        try writeHttpFmt(
            stream,
            if (e == error.NoConnectedPeers) @as(u16, 503) else @as(u16, 502),
            "text/plain",
            "bzz retrieval failed: {any}\n",
            .{e},
        );
        return;
    };
    defer rc.deinit();

    // Decrypted root view. For unencrypted refs this is the raw
    // payload (rc.data); for encrypted refs, this is the decrypted
    // plaintext payload (after `decryptChunk` strips the 8-byte span
    // prefix and trims to real-span).
    var root_payload: []const u8 = rc.data;
    var owned_decrypted_root: ?[]u8 = null;
    defer if (owned_decrypted_root) |d| node.allocator.free(d);
    if (ref.key) |k| {
        const wire = try node.allocator.alloc(u8, bmt.SPAN_SIZE + rc.data.len);
        defer node.allocator.free(wire);
        std.mem.writeInt(u64, wire[0..bmt.SPAN_SIZE], rc.span, .little);
        @memcpy(wire[bmt.SPAN_SIZE..], rc.data);
        owned_decrypted_root = encryption.decryptChunk(node.allocator, k, wire) catch |e| {
            try writeHttpFmt(stream, 502, "text/plain", "decrypt root failed: {any}\n", .{e});
            return;
        };
        // For mantaray detection, skip the 8-byte span prefix.
        root_payload = owned_decrypted_root.?[bmt.SPAN_SIZE..];
    }

    // Step 2: is the root a mantaray manifest?
    //   - Yes + no inner path: resolve default file via root metadata.
    //   - Yes + inner path: walk that path in the trie.
    //   - No: serve the chunk-tree at the root ref directly (only valid
    //     with empty inner path; with a path we'd have nothing to look
    //     up in).
    const file_ref: Ref = if (mantaray.looksLikeManifest(root_payload)) blk: {
        var manifest_root = mantaray.parse(node.allocator, root_payload) catch |e| {
            try writeHttpFmt(stream, 502, "text/plain", "bad manifest: {any}\n", .{e});
            return;
        };
        defer manifest_root.deinit();

        const entry_ref = if (inner_path.len == 0)
            mantaray.resolveDefaultFile(
                node.allocator,
                &manifest_root,
                @ptrCast(node),
                &mantarayLoaderAdapter,
            ) catch |e| {
                try writeHttpFmt(stream, 502, "text/plain", "manifest resolve failed: {any}\n", .{e});
                return;
            }
        else
            mantaray.lookup(
                node.allocator,
                &manifest_root,
                inner_path,
                @ptrCast(node),
                &mantarayLoaderAdapter,
            ) catch |e| {
                const code: u16 = if (e == mantaray.Error.PathNotFound) 404 else 502;
                try writeHttpFmt(stream, code, "text/plain", "manifest lookup failed: {any}\n", .{e});
                return;
            };
        defer node.allocator.free(entry_ref);

        // Manifests built with encryption store 64-byte entry refs
        // (32-byte chunk addr ‖ 32-byte file-tree key); plain manifests
        // store 32-byte refs.
        const fr = switch (entry_ref.len) {
            bmt.HASH_SIZE => Ref{ .addr = blk2: {
                var a: [bmt.HASH_SIZE]u8 = undefined;
                @memcpy(&a, entry_ref);
                break :blk2 a;
            } },
            encryption.REFERENCE_SIZE => fr_blk: {
                var a: [bmt.HASH_SIZE]u8 = undefined;
                var k: [encryption.KEY_LEN]u8 = undefined;
                @memcpy(&a, entry_ref[0..bmt.HASH_SIZE]);
                @memcpy(&k, entry_ref[bmt.HASH_SIZE..]);
                break :fr_blk Ref{ .addr = a, .key = k };
            },
            else => {
                try writeHttpFmt(stream, 502, "text/plain", "unexpected ref size: {d}\n", .{entry_ref.len});
                return;
            },
        };
        std.debug.print(
            "[api] /bzz: manifest{s}{s} resolved to {s}{s}\n",
            .{
                if (inner_path.len > 0) " path=" else " (default doc)",
                inner_path,
                std.fmt.bytesToHex(fr.addr, .lower),
                if (fr.key != null) " (encrypted)" else "",
            },
        );
        break :blk fr;
    } else blk: {
        if (inner_path.len > 0) {
            try writeHttp(stream, 404, "text/plain", "reference is not a manifest; cannot resolve path\n");
            return;
        }
        break :blk ref;
    };

    // Step 3: walk the chunk-tree at `file_ref` and stream the bytes.
    const file_bytes = joinByRef(node, file_ref) catch |e| {
        try writeHttpFmt(
            stream,
            if (e == error.NoConnectedPeers) @as(u16, 503) else @as(u16, 502),
            "text/plain",
            "bzz retrieval failed: {any}\n",
            .{e},
        );
        return;
    };
    defer node.allocator.free(file_bytes);

    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n",
        .{file_bytes.len},
    );
    try stream.writeAll(hdr);
    try stream.writeAll(file_bytes);
}

/// Joiner-by-ref: dispatches to `joiner.join` (32-byte ref) or
/// `joiner.joinEncrypted` (64-byte ref) depending on whether the Ref
/// carries a symmetric key.
fn joinByRef(node: *P2PNode, ref: Ref) ![]u8 {
    if (ref.key) |k| {
        return joiner.joinEncrypted(node.allocator, @ptrCast(node), &joinerFetchAdapter, ref.addr, k);
    }
    return joiner.join(node.allocator, @ptrCast(node), &joinerFetchAdapter, ref.addr);
}

// ---- bee-compatible identity / health ----

/// `GET /health` and `GET /readiness`. Bee returns
/// `{"status":"ok","version":"...","apiVersion":"..."}`.
fn handleHealth(node: *P2PNode, stream: net.Stream) !void {
    _ = node;
    try writeJson(stream, 200,
        \\{"status":"ok","version":"0.3.0-zigbee","apiVersion":"5.0.0"}
    );
}

/// `GET /node`. Bee returns `{"beeMode":"...","chequebookEnabled":bool,"swapEnabled":bool}`.
/// Bee's mode enum already has `"ultra-light"` (`UltraLightMode`); that's exactly us.
fn handleNode(node: *P2PNode, stream: net.Stream) !void {
    _ = node;
    try writeJson(stream, 200,
        \\{"beeMode":"ultra-light","chequebookEnabled":false,"swapEnabled":false}
    );
}

/// `GET /addresses`. Bee returns:
/// `{"overlay":"<hex>","underlay":[...],"ethereum":"<0x...>","chain_address":"<0x...>","publicKey":"<hex>","pssPublicKey":"<hex>"}`.
fn handleAddresses(node: *P2PNode, stream: net.Stream) !void {
    var eth: [identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
    node.id.ethereumAddress(&eth);
    var pubc: [identity.COMPRESSED_PUBKEY_SIZE]u8 = undefined;
    try node.id.compressedPublicKey(&pubc);

    var body = std.ArrayList(u8){};
    defer body.deinit(node.allocator);

    try body.appendSlice(node.allocator, "{\"overlay\":\"");
    try writeHex(&body, node.allocator, &node.overlay);
    try body.appendSlice(node.allocator, "\",\"underlay\":[],\"ethereum\":\"0x");
    try writeHex(&body, node.allocator, &eth);
    try body.appendSlice(node.allocator, "\",\"chain_address\":\"0x");
    try writeHex(&body, node.allocator, &eth);
    try body.appendSlice(node.allocator, "\",\"publicKey\":\"");
    try writeHex(&body, node.allocator, &pubc);
    // pssPublicKey: bee uses a separate dedicated key for pss. We don't
    // have one; bee allows reusing the libp2p/secp256k1 key as a default
    // for nodes that didn't generate a separate one — match that.
    try body.appendSlice(node.allocator, "\",\"pssPublicKey\":\"");
    try writeHex(&body, node.allocator, &pubc);
    try body.appendSlice(node.allocator, "\"}");

    try writeJsonOwned(stream, 200, body.items);
}

/// `GET /peers` — bee shape: `{"peers":[{"address":"<overlay>","fullNode":bool}]}`.
fn handlePeersBee(node: *P2PNode, stream: net.Stream) !void {
    var body = std.ArrayList(u8){};
    defer body.deinit(node.allocator);

    try body.appendSlice(node.allocator, "{\"peers\":[");
    node.connections_mtx.lock();
    var first = true;
    for (node.connections.items) |c| {
        // Skip connections whose accept thread has exited; they're
        // pending reaping by the next manage tick. Reporting them as
        // "connected" would mislead bee tools polling /peers.
        if (c.isDead()) continue;
        if (!first) try body.append(node.allocator, ',');
        first = false;
        try body.appendSlice(node.allocator, "{\"address\":\"");
        try writeHex(&body, node.allocator, &c.peer_overlay);
        try body.appendSlice(node.allocator, "\",\"fullNode\":");
        try body.appendSlice(node.allocator, if (c.peer_full_node) "true" else "false");
        try body.append(node.allocator, '}');
    }
    node.connections_mtx.unlock();
    try body.appendSlice(node.allocator, "]}");

    try writeJsonOwned(stream, 200, body.items);
}

/// `GET /topology` — bee returns a Kademlia snapshot with per-bin
/// population. We expose what we have: own overlay, connection count,
/// and per-bin counts derived from the peer table. Field names are
/// bee-shape but the schema is a subset (we don't track timestamps,
/// reachability, etc.).
fn handleTopology(node: *P2PNode, stream: net.Stream) !void {
    var body = std.ArrayList(u8){};
    defer body.deinit(node.allocator);

    var line_buf: [256]u8 = undefined;
    try body.appendSlice(node.allocator, "{\"baseAddr\":\"");
    try writeHex(&body, node.allocator, &node.overlay);
    try body.appendSlice(node.allocator, "\",\"population\":");
    {
        const s = try std.fmt.bufPrint(&line_buf, "{d}", .{node.peers.count()});
        try body.appendSlice(node.allocator, s);
    }
    try body.appendSlice(node.allocator, ",\"connected\":");
    {
        const s = try std.fmt.bufPrint(&line_buf, "{d}", .{node.connectionCount()});
        try body.appendSlice(node.allocator, s);
    }
    try body.appendSlice(node.allocator, ",\"bins\":{");
    node.peersLock();
    const depths = node.peers.binDepths();
    var first_bin = true;
    for (depths, 0..) |d, i| {
        if (d == 0) continue;
        if (!first_bin) try body.append(node.allocator, ',');
        first_bin = false;
        const s = try std.fmt.bufPrint(&line_buf, "\"{d}\":{{\"population\":{d}}}", .{ i, d });
        try body.appendSlice(node.allocator, s);
    }
    node.peersUnlock();
    try body.appendSlice(node.allocator, "}}");

    try writeJsonOwned(stream, 200, body.items);
}

// ---- bee-compatible storage GETs ----

/// `GET /chunks/<addr>` — bee returns the raw chunk = `span(8) ‖ payload`,
/// content-type `binary/octet-stream`. Same protocol underneath as
/// `/retrieve` but a different output shape (we re-prepend the span here).
fn handleChunkBee(
    node: *P2PNode,
    stream: net.Stream,
    addr: [bmt.HASH_SIZE]u8,
) !void {
    var rc = node.retrieveChunkIterating(addr) catch |e| {
        const code: u16 = if (e == error.NoConnectedPeers) 503 else 404;
        try writeHttpFmt(stream, code, "text/plain", "{any}\n", .{e});
        return;
    };
    defer rc.deinit();

    const total = bmt.SPAN_SIZE + rc.data.len;
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: binary/octet-stream\r\nContent-Length: {d}\r\n\r\n",
        .{total},
    );
    try stream.writeAll(hdr);
    var span_buf: [bmt.SPAN_SIZE]u8 = undefined;
    std.mem.writeInt(u64, &span_buf, rc.span, .little);
    try stream.writeAll(&span_buf);
    try stream.writeAll(rc.data);
}

/// `GET /bytes/<ref>` — bee runs the joiner over `<ref>` directly,
/// without manifest detection. (POST /bytes uploads always produce
/// raw CAC trees, so the matching GET shouldn't second-guess.)
fn handleBytes(
    node: *P2PNode,
    stream: net.Stream,
    ref: Ref,
) !void {
    const file_bytes = joinByRef(node, ref) catch |e| {
        const code: u16 = if (e == error.NoConnectedPeers) 503 else 502;
        try writeHttpFmt(stream, code, "text/plain", "bytes retrieval failed: {any}\n", .{e});
        return;
    };
    defer node.allocator.free(file_bytes);

    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n",
        .{file_bytes.len},
    );
    try stream.writeAll(hdr);
    try stream.writeAll(file_bytes);
}

// ---- JSON / hex helpers ----

fn writeJson(stream: net.Stream, status: u16, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\n\r\n",
        .{ status, body.len },
    );
    try stream.writeAll(hdr);
    try stream.writeAll(body);
}

fn writeJsonOwned(stream: net.Stream, status: u16, body: []const u8) !void {
    return writeJson(stream, status, body);
}

fn writeHex(body: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    const hex_chars = "0123456789abcdef";
    for (bytes) |b| {
        try body.append(allocator, hex_chars[b >> 4]);
        try body.append(allocator, hex_chars[b & 0xF]);
    }
}

/// Loader adapter for the mantaray walker. Given a child reference, fetch
/// the chunk and parse it as a mantaray Node. For 64-byte refs (encrypted
/// manifests, 0.5b), the second half is the symmetric key; we decrypt the
/// retrieved chunk before parsing it as the next manifest node.
fn mantarayLoaderAdapter(
    ctx_opaque: *anyopaque,
    ref: []const u8,
    out: *mantaray.Node,
) anyerror!void {
    const node: *P2PNode = @ptrCast(@alignCast(ctx_opaque));

    var addr: [bmt.HASH_SIZE]u8 = undefined;
    var key: ?[encryption.KEY_LEN]u8 = null;
    switch (ref.len) {
        bmt.HASH_SIZE => @memcpy(&addr, ref),
        encryption.REFERENCE_SIZE => {
            @memcpy(&addr, ref[0..bmt.HASH_SIZE]);
            var k: [encryption.KEY_LEN]u8 = undefined;
            @memcpy(&k, ref[bmt.HASH_SIZE..]);
            key = k;
        },
        else => return error.UnsupportedRefSize,
    }

    var rc = try node.retrieveChunkIterating(addr);
    defer rc.deinit();

    if (key) |k| {
        const wire = try node.allocator.alloc(u8, bmt.SPAN_SIZE + rc.data.len);
        defer node.allocator.free(wire);
        std.mem.writeInt(u64, wire[0..bmt.SPAN_SIZE], rc.span, .little);
        @memcpy(wire[bmt.SPAN_SIZE..], rc.data);

        const decrypted = try encryption.decryptChunk(node.allocator, k, wire);
        defer node.allocator.free(decrypted);
        out.* = try mantaray.parse(node.allocator, decrypted[bmt.SPAN_SIZE..]);
    } else {
        out.* = try mantaray.parse(node.allocator, rc.data);
    }
}

fn writeHttp(stream: net.Stream, status: u16, content_type: []const u8, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} \r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try stream.writeAll(hdr);
    try stream.writeAll(body);
}

fn writeHttpFmt(stream: net.Stream, status: u16, content_type: []const u8, comptime fmt: []const u8, args: anytype) !void {
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, fmt, args);
    try writeHttp(stream, status, content_type, body);
}

// ---- helpers ----

fn parseIpv4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}
