//! Per-peer SWAP accounting state — tracks how much we owe each bee peer
//! and decides when to issue a cheque to clear that debt before bee's
//! disconnect threshold cuts us off.
//!
//! ## Why this is here
//!
//! Bee announces a payment threshold (~13.5M wei for full nodes) when it
//! connects. Every chunk we retrieve increments bee's view of our debt; once
//! debt > threshold, bee disconnects us and logs `apply debit: disconnect
//! threshold exceeded`. Without SWAP this caps retrieval at ~25–30 chunks
//! per peer.
//!
//! With SWAP we issue an EIP-712-signed cheque before reaching the threshold;
//! bee credits us, our debt counter resets in bee's view, retrieval continues.
//!
//! ## Model
//!
//! Per-peer state:
//!   * `chunks_since_last_cheque` (in-memory only) — incremented on every
//!     successful retrieval from this peer; reset on cheque-sent.
//!   * `last_cumulative_payout_wei` (persistent, atomic write) — the
//!     cumulativePayout value of the last cheque we sent. Cheques are
//!     cumulative; each new cheque must be strictly greater than the value
//!     bee has stored for us.
//!
//! ## Persistence layout (B2, 2026-04-29)
//!
//! Cumulative-payout state lives **with the chequebook credential**, not
//! in a separate `~/.zigbee/accounting/` tree. The state file path is
//! derived from the chequebook path: `chequebook.json` → `chequebook.state.json`.
//! Format:
//!
//!     { "version": 1,
//!       "peers": { "<peer-overlay-hex>": "<cumulative-decimal>" , ... } }
//!
//! Why bound to the chequebook: cumulativePayout is logically per-(chequebook,
//! peer). A cheque means "*this* chequebook owes *this* peer this much
//! cumulative." Wiping the cumulative without also wiping the chequebook
//! means the next cheque undershoots bee's stored value and gets rejected
//! as a replay. Putting the data next to the chequebook makes the invariant
//! impossible to violate by accident: if you keep the chequebook, you keep
//! its state. If you wipe both together (e.g., factory reset), you must
//! re-provision, which gives bee a new chequebook anyway.
//!
//! When no `--chequebook` is provided, accounting still tracks chunk
//! counters in memory (so adding `--chequebook` later is a one-line toggle)
//! but writes nothing to disk — there's no chequebook to bind state to.
//!
//! ## When `chunks_since_last_cheque ≥ TRIGGER_CHUNKS`
//!
//!   1. Open a swap stream and negotiate headers (exchange_rate, deduction).
//!   2. delta_wei = exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction
//!      (sized in base units rather than wei because bee's accounting is
//!       denominated in base units; pinning a wei constant scales inversely
//!       with whatever exchange_rate the peer announces).
//!   3. new_cumulative = last_cumulative + delta_wei.
//!   4. Persist new_cumulative *before* signing — if we crash between
//!      persist and send, the next attempt re-uses the same value and bee
//!      accepts it as long as the previous attempt didn't reach bee.
//!   5. Sign cheque, send it on the negotiated swap stream.
//!   6. On success: zero `chunks_since_last_cheque`.
//!   7. On failure: log, leave counter elevated; subsequent retrievals will
//!      retrigger the issue path.
//!
//! ## What this module owns
//!
//! Just the accounting state + persistence. Cheque construction uses
//! `src/cheque.zig`; protocol I/O uses `src/swap.zig`. Wire-up to retrieval
//! happens in `src/p2p.zig`.

const std = @import("std");
const cheque = @import("cheque.zig");

/// Number of chunks we'll let accumulate before triggering a cheque.
///
/// Tightened to 3 after the 2026-04-29 live test against a funded
/// chequebook revealed a races issue: cheque issuance is
/// asynchronous (separate stream + multistream-select + headers
/// exchange) so retrievals 6–8 slip through while the cheque is
/// still in flight. Bee disconnected at retrieval 9 because debt
/// reached its announced payment_threshold *before* the cheque
/// arrived. With 3, we initiate the cheque while debt is still ~3×
/// per-chunk-cost, leaving real headroom for the cheque to land.
pub const TRIGGER_CHUNKS: u64 = 3;

/// How many bee-accounting base units we want to credit bee per
/// cheque. The actual wire amount in BZZ wei is computed at emit
/// time as `target × exchange_rate + deduction`, where
/// exchange_rate and deduction come from the swap-stream header
/// negotiation just before send.
///
/// Why base units, not wei: bee's accounting (payment_threshold,
/// per-chunk debit, disconnect threshold) is denominated in base
/// units; the BZZ wei in the cheque is a bee-side conversion via
/// `credited_base_units = (cumulative_payout - deduction) / exchange_rate`.
/// Pinning a constant in wei is wrong because it silently scales
/// inversely with whatever exchange_rate the peer announces.
///
/// In the 2026-04-29 live test bee announced payment_threshold =
/// 1.35 M base units. 10 M is ~7× that — enough to clear bee's
/// debt counter with comfortable headroom every cheque, while
/// keeping per-cheque cost small enough that a 1 BZZ chequebook
/// funds many thousands of cheques even at high exchange rates.
pub const CREDIT_TARGET_BASE_UNITS: u64 = 10_000_000;

pub const Error = error{
    InvalidStateFile,
    OutOfMemory,
};

const PEER_OVERLAY_LEN: usize = 32;
const FILE_VERSION: u8 = 1;

/// In-memory per-peer accounting record. `last_cumulative_payout_wei` is the
/// authoritative wire value to put into the *next* cheque after incrementing
/// by the caller-supplied `delta_wei` in `buildCheque`.
const PeerState = struct {
    overlay: [PEER_OVERLAY_LEN]u8,
    chunks_since_last_cheque: u64 = 0,
    last_cumulative_payout_wei: u256 = 0,
};

pub const Accounting = struct {
    allocator: std.mem.Allocator,
    /// Path to the single JSON state file (peer-overlay → cumulative_wei).
    /// Null = ephemeral mode; no persistence (no chequebook to bind to).
    /// We own this slice when non-null.
    state_path: ?[]u8,
    mtx: std.Thread.Mutex = .{},
    /// peer overlay → state. Owned. Caller of openOrCreate hands us the
    /// allocator; we use it for both keys (none) and value pointers.
    map: std.AutoHashMapUnmanaged([PEER_OVERLAY_LEN]u8, *PeerState) = .{},

    /// Open or create the accounting state. If `state_path` is non-null and
    /// the file exists, the persistent peer→cumulative map is loaded; if it
    /// doesn't exist we start empty and write on first `buildCheque`. If
    /// `state_path` is null, accounting runs in fully ephemeral mode (chunk
    /// counters in memory, no persistence — typical when zigbee runs
    /// without `--chequebook`).
    pub fn openOrCreate(allocator: std.mem.Allocator, state_path: ?[]const u8) !*Accounting {
        const self = try allocator.create(Accounting);
        errdefer allocator.destroy(self);

        const owned_path: ?[]u8 = if (state_path) |p| try allocator.dupe(u8, p) else null;
        errdefer if (owned_path) |p| allocator.free(p);

        self.* = .{
            .allocator = allocator,
            .state_path = owned_path,
        };

        if (owned_path) |p| {
            // Make sure the parent directory exists — the chequebook usually
            // lives in `~/.zigbee/` which already exists, but a user pointing
            // `--chequebook` at a fresh path needs us to mkdir -p.
            if (std.fs.path.dirname(p)) |dir| {
                std.fs.cwd().makePath(dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            }
            self.loadStateFile() catch |e| switch (e) {
                error.FileNotFound => {}, // fresh start, no prior state
                else => return e,
            };
        }
        return self;
    }

    pub fn deinit(self: *Accounting) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.allocator.destroy(v.*);
        self.map.deinit(self.allocator);
        if (self.state_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    /// Increment our debt to `peer` by `n_chunks`. Returns true if we should
    /// now issue a cheque to this peer (the trigger threshold has been
    /// crossed since the last cheque).
    pub fn charge(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8, n_chunks: u64) !bool {
        self.mtx.lock();
        defer self.mtx.unlock();

        const ps = try self.getOrCreate(peer);
        ps.chunks_since_last_cheque += n_chunks;
        return ps.chunks_since_last_cheque >= TRIGGER_CHUNKS;
    }

    /// Build the next cheque for `peer`, with cumulativePayout incremented
    /// by `delta_wei`. The caller computes delta_wei from the negotiated
    /// swap-stream headers (exchange_rate × CREDIT_TARGET_BASE_UNITS +
    /// deduction). Persists the new cumulative *before* returning, so if
    /// the caller crashes between buildCheque and sendCheque, recovery
    /// won't issue a stale (re-decreasing) cumulative value.
    ///
    /// The returned `Cheque` is unsigned; caller signs with the chequebook
    /// owner's private key and ships via `swap.sendCheque`.
    pub fn buildCheque(
        self: *Accounting,
        peer: [PEER_OVERLAY_LEN]u8,
        chequebook: [20]u8,
        beneficiary: [20]u8,
        delta_wei: u256,
    ) !cheque.Cheque {
        self.mtx.lock();
        defer self.mtx.unlock();

        const ps = try self.getOrCreate(peer);
        const new_cumulative = ps.last_cumulative_payout_wei + delta_wei;

        // Tentatively update in-memory state, then persist the snapshot. If
        // the persist fails, roll back so we don't return a cheque whose
        // cumulative isn't durable.
        const prev_cumulative = ps.last_cumulative_payout_wei;
        ps.last_cumulative_payout_wei = new_cumulative;
        if (self.state_path) |path| {
            self.writeStateFileLocked(path) catch |e| {
                ps.last_cumulative_payout_wei = prev_cumulative;
                return e;
            };
        }

        return cheque.Cheque{
            .chequebook = chequebook,
            .beneficiary = beneficiary,
            .cumulative_payout = new_cumulative,
        };
    }

    /// After a cheque has been successfully transmitted, reset the per-peer
    /// chunk counter. The persistent cumulative was already written by
    /// buildCheque.
    pub fn markChequeSent(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8) void {
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.map.get(peer)) |ps| ps.chunks_since_last_cheque = 0;
    }

    /// Read-only snapshot of the per-peer state. Returns null if we've never
    /// charged this peer. Mostly for tests + observability.
    pub fn snapshot(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8) ?PeerStateSnapshot {
        self.mtx.lock();
        defer self.mtx.unlock();
        const ps = self.map.get(peer) orelse return null;
        return .{
            .chunks_since_last_cheque = ps.chunks_since_last_cheque,
            .last_cumulative_payout_wei = ps.last_cumulative_payout_wei,
        };
    }

    pub const PeerStateSnapshot = struct {
        chunks_since_last_cheque: u64,
        last_cumulative_payout_wei: u256,
    };

    /// Set this peer's persistent cumulative directly. Used by external
    /// bootstrap paths (e.g., a wrapper that queries bee's
    /// `GET /chequebook/cheque` after a partial-state restore and seeds
    /// our local view to match bee's authoritative value). Persists
    /// immediately. Will not regress an existing higher cumulative —
    /// returns silently in that case.
    pub fn seedCumulative(
        self: *Accounting,
        peer: [PEER_OVERLAY_LEN]u8,
        cumulative_wei: u256,
    ) !void {
        self.mtx.lock();
        defer self.mtx.unlock();

        const ps = try self.getOrCreate(peer);
        if (cumulative_wei <= ps.last_cumulative_payout_wei) return;
        ps.last_cumulative_payout_wei = cumulative_wei;
        if (self.state_path) |path| try self.writeStateFileLocked(path);
    }

    // ---- internals --------------------------------------------------------

    fn getOrCreate(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8) !*PeerState {
        if (self.map.get(peer)) |ps| return ps;
        const ps = try self.allocator.create(PeerState);
        errdefer self.allocator.destroy(ps);
        ps.* = .{ .overlay = peer };
        try self.map.put(self.allocator, peer, ps);
        return ps;
    }

    /// Serialize the entire peers map to a JSON document and atomically
    /// replace the state file. Caller holds `self.mtx`.
    fn writeStateFileLocked(self: *Accounting, path: []const u8) !void {
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"version\":1,\"peers\":{");
        var first = true;
        var it = self.map.valueIterator();
        while (it.next()) |v_ptr| {
            const ps = v_ptr.*;
            if (!first) try body.appendSlice(self.allocator, ",");
            first = false;
            try body.appendSlice(self.allocator, "\"");
            const hex_str = std.fmt.bytesToHex(ps.overlay, .lower);
            try body.appendSlice(self.allocator, &hex_str);
            try body.appendSlice(self.allocator, "\":\"");
            var dec_buf: [78]u8 = undefined;
            const dec = formatU256Decimal(ps.last_cumulative_payout_wei, &dec_buf);
            try body.appendSlice(self.allocator, dec);
            try body.appendSlice(self.allocator, "\"");
        }
        try body.appendSlice(self.allocator, "}}\n");

        try atomicWrite(self.allocator, path, body.items);
    }

    fn loadStateFile(self: *Accounting) !void {
        const path = self.state_path.?;
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const data = try f.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return Error.InvalidStateFile;
        defer parsed.deinit();

        if (parsed.value != .object) return Error.InvalidStateFile;
        const peers_val = parsed.value.object.get("peers") orelse return Error.InvalidStateFile;
        if (peers_val != .object) return Error.InvalidStateFile;

        var it = peers_val.object.iterator();
        while (it.next()) |kv| {
            const overlay_hex = kv.key_ptr.*;
            if (overlay_hex.len != PEER_OVERLAY_LEN * 2) continue;
            var overlay: [PEER_OVERLAY_LEN]u8 = undefined;
            _ = std.fmt.hexToBytes(&overlay, overlay_hex) catch continue;

            const cumulative: u256 = switch (kv.value_ptr.*) {
                .string => |s| parseU256Decimal(s) catch continue,
                .integer => |n| if (n < 0) continue else @intCast(n),
                .number_string => |s| parseU256Decimal(s) catch continue,
                else => continue,
            };

            const ps = try self.allocator.create(PeerState);
            errdefer self.allocator.destroy(ps);
            ps.* = .{
                .overlay = overlay,
                .chunks_since_last_cheque = 0,
                .last_cumulative_payout_wei = cumulative,
            };
            try self.map.put(self.allocator, overlay, ps);
        }
    }
};

fn formatU256Decimal(value: u256, out: []u8) []u8 {
    if (value == 0) {
        out[0] = '0';
        return out[0..1];
    }
    var v = value;
    var i: usize = out.len;
    while (v > 0) {
        i -= 1;
        const d: u8 = @intCast(v % 10);
        out[i] = '0' + d;
        v /= 10;
    }
    const len = out.len - i;
    std.mem.copyForwards(u8, out[0..len], out[i..]);
    return out[0..len];
}

fn parseU256Decimal(s: []const u8) !u256 {
    if (s.len == 0) return error.InvalidNumber;
    var v: u256 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidNumber;
        v = std.math.mul(u256, v, 10) catch return error.NumberOverflow;
        v = std.math.add(u256, v, c - '0') catch return error.NumberOverflow;
    }
    return v;
}

/// Atomic write: tempfile + fsync + rename. Same pattern as identity.zig and
/// store.zig.
fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);

    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(data);
        try f.sync();
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Derive the accounting state-file path from a chequebook-credential path.
/// `foo.json` → `foo.state.json`; anything else → append `.state.json`.
/// Caller owns the returned slice.
pub fn deriveStatePath(allocator: std.mem.Allocator, chequebook_path: []const u8) ![]u8 {
    const json_suffix = ".json";
    if (std.mem.endsWith(u8, chequebook_path, json_suffix)) {
        const stem = chequebook_path[0 .. chequebook_path.len - json_suffix.len];
        return std.fmt.allocPrint(allocator, "{s}.state.json", .{stem});
    }
    return std.fmt.allocPrint(allocator, "{s}.state.json", .{chequebook_path});
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Synthetic cheque delta used by buildCheque-call sites in this file's
/// tests. In production code chargeAndMaybeIssue computes
/// `exchange_rate × CREDIT_TARGET_BASE_UNITS + deduction` from the
/// negotiated swap headers; tests don't need a swap stream so they pick
/// any positive u256.
const TEST_DELTA_WEI: u256 = 100_000_000_000_000;

fn tmpStatePath(allocator: std.mem.Allocator, dir: *std.testing.TmpDir) ![]u8 {
    const root = try dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "chequebook.state.json" });
}

test "accounting: charge below trigger does not signal issue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tmpStatePath(testing.allocator, &tmp);
    defer testing.allocator.free(state_path);

    const acc = try Accounting.openOrCreate(testing.allocator, state_path);
    defer acc.deinit();

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xAA);

    // Charge TRIGGER_CHUNKS - 1 chunks total in three batches; each below
    // the trigger so charge() returns false every time.
    const total_below: u64 = TRIGGER_CHUNKS - 1;
    const batch: u64 = total_below / 3;
    const tail: u64 = total_below - batch * 2;
    try testing.expect(!try acc.charge(peer, batch));
    try testing.expect(!try acc.charge(peer, batch));
    try testing.expect(!try acc.charge(peer, tail));

    const snap = acc.snapshot(peer).?;
    try testing.expectEqual(total_below, snap.chunks_since_last_cheque);
    try testing.expectEqual(@as(u256, 0), snap.last_cumulative_payout_wei);
}

test "accounting: trigger at TRIGGER_CHUNKS, buildCheque advances cumulative" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tmpStatePath(testing.allocator, &tmp);
    defer testing.allocator.free(state_path);

    const acc = try Accounting.openOrCreate(testing.allocator, state_path);
    defer acc.deinit();

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xBB);

    // Charge enough to trigger.
    try testing.expect(!try acc.charge(peer, TRIGGER_CHUNKS - 1));
    try testing.expect(try acc.charge(peer, 1));

    const chequebook = [_]u8{0xCB} ** 20;
    const beneficiary = [_]u8{0xBE} ** 20;

    // First cheque: cumulative = 0 + TEST_DELTA_WEI.
    const c1 = try acc.buildCheque(peer, chequebook, beneficiary, TEST_DELTA_WEI);
    try testing.expectEqual(TEST_DELTA_WEI, c1.cumulative_payout);
    try testing.expectEqualSlices(u8, &chequebook, &c1.chequebook);
    try testing.expectEqualSlices(u8, &beneficiary, &c1.beneficiary);

    acc.markChequeSent(peer);
    const snap1 = acc.snapshot(peer).?;
    try testing.expectEqual(@as(u64, 0), snap1.chunks_since_last_cheque);
    try testing.expectEqual(TEST_DELTA_WEI, snap1.last_cumulative_payout_wei);

    // Second cheque: cumulative grows monotonically.
    _ = try acc.charge(peer, TRIGGER_CHUNKS);
    const c2 = try acc.buildCheque(peer, chequebook, beneficiary, TEST_DELTA_WEI);
    try testing.expectEqual(2 * TEST_DELTA_WEI, c2.cumulative_payout);
}

test "accounting: state survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tmpStatePath(testing.allocator, &tmp);
    defer testing.allocator.free(state_path);

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xCC);

    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();
        _ = try acc.charge(peer, TRIGGER_CHUNKS);
        const chequebook = [_]u8{0xCB} ** 20;
        const beneficiary = [_]u8{0xBE} ** 20;
        _ = try acc.buildCheque(peer, chequebook, beneficiary, TEST_DELTA_WEI);
        acc.markChequeSent(peer);
    }

    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();
        const snap = acc.snapshot(peer).?;
        // chunks_since_last_cheque is in-memory only; resets to 0 on reopen.
        try testing.expectEqual(@as(u64, 0), snap.chunks_since_last_cheque);
        // last_cumulative_payout_wei is persistent and must round-trip.
        try testing.expectEqual(TEST_DELTA_WEI, snap.last_cumulative_payout_wei);
    }
}

test "accounting: per-peer state is isolated and round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tmpStatePath(testing.allocator, &tmp);
    defer testing.allocator.free(state_path);

    var p1: [32]u8 = undefined;
    @memset(&p1, 0x11);
    var p2: [32]u8 = undefined;
    @memset(&p2, 0x22);

    const cb = [_]u8{0xCB} ** 20;
    const be = [_]u8{0xBE} ** 20;

    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();

        _ = try acc.charge(p1, TRIGGER_CHUNKS);
        _ = try acc.buildCheque(p1, cb, be, TEST_DELTA_WEI);
        acc.markChequeSent(p1);

        _ = try acc.charge(p2, 5);

        const s1 = acc.snapshot(p1).?;
        const s2 = acc.snapshot(p2).?;
        try testing.expectEqual(TEST_DELTA_WEI, s1.last_cumulative_payout_wei);
        try testing.expectEqual(@as(u256, 0), s2.last_cumulative_payout_wei);
        try testing.expectEqual(@as(u64, 5), s2.chunks_since_last_cheque);
    }

    // Reopen — only p1 has persistent state (p2's cumulative is still 0,
    // so it never wrote to disk via buildCheque). Both peers' chunk counters
    // reset.
    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();
        const s1 = acc.snapshot(p1).?;
        try testing.expectEqual(TEST_DELTA_WEI, s1.last_cumulative_payout_wei);
        try testing.expectEqual(@as(u64, 0), s1.chunks_since_last_cheque);
        // p2 had no buildCheque call, so its 0 cumulative wasn't independently
        // persisted; it's recreated on next access.
        try testing.expectEqual(@as(?Accounting.PeerStateSnapshot, null), acc.snapshot(p2));
    }
}

test "accounting: ephemeral mode (no state path) tracks but doesn't persist" {
    const acc = try Accounting.openOrCreate(testing.allocator, null);
    defer acc.deinit();

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xEE);

    _ = try acc.charge(peer, TRIGGER_CHUNKS);
    const cb = [_]u8{0xCB} ** 20;
    const be = [_]u8{0xBE} ** 20;
    const c = try acc.buildCheque(peer, cb, be, TEST_DELTA_WEI);
    try testing.expectEqual(TEST_DELTA_WEI, c.cumulative_payout);
    // No file to assert against; the absence of an error path is the test.
}

test "accounting: seedCumulative bootstraps from external authoritative source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tmpStatePath(testing.allocator, &tmp);
    defer testing.allocator.free(state_path);

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xDD);

    const seed_value: u256 = 800_000_000_000_000;

    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();
        try acc.seedCumulative(peer, seed_value);
        const s = acc.snapshot(peer).?;
        try testing.expectEqual(seed_value, s.last_cumulative_payout_wei);

        // seedCumulative does not regress.
        try acc.seedCumulative(peer, seed_value - 1);
        try testing.expectEqual(seed_value, acc.snapshot(peer).?.last_cumulative_payout_wei);
    }

    // Reopen: seeded value persisted.
    {
        const acc = try Accounting.openOrCreate(testing.allocator, state_path);
        defer acc.deinit();
        try testing.expectEqual(seed_value, acc.snapshot(peer).?.last_cumulative_payout_wei);

        // Subsequent buildCheque builds on top of the seeded value.
        _ = try acc.charge(peer, TRIGGER_CHUNKS);
        const cb = [_]u8{0xCB} ** 20;
        const be = [_]u8{0xBE} ** 20;
        const c = try acc.buildCheque(peer, cb, be, TEST_DELTA_WEI);
        try testing.expectEqual(seed_value + TEST_DELTA_WEI, c.cumulative_payout);
    }
}

test "accounting: deriveStatePath chequebook.json → chequebook.state.json" {
    const a = try deriveStatePath(testing.allocator, "/home/x/.zigbee/chequebook.json");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/home/x/.zigbee/chequebook.state.json", a);

    const b = try deriveStatePath(testing.allocator, "/tmp/cb");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/cb.state.json", b);
}
