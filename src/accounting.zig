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
//!   * `chunks_since_last_cheque` (in-memory) — incremented on every successful
//!     retrieval from this peer.
//!   * `last_cumulative_payout_wei` (persistent, atomic write) — the
//!     cumulativePayout value of the last cheque we sent. Cheques are
//!     cumulative; each new cheque must be strictly greater.
//!
//! When `chunks_since_last_cheque ≥ TRIGGER_CHUNKS`:
//!   1. new_cumulative = last_cumulative + CHEQUE_AMOUNT_WEI
//!   2. Persist new_cumulative *before* signing — if we crash between persist
//!      and send, the next attempt will retry with the same value and bee
//!      will accept it as long as the previous attempt didn't reach bee.
//!   3. Sign cheque, send it on /swarm/swap/1.0.0/swap.
//!   4. On success: zero `chunks_since_last_cheque`.
//!   5. On failure: log, leave counter elevated; subsequent retrievals will
//!      retrigger the issue path.
//!
//! ## What this module owns
//!
//! Just the accounting state + persistence. Cheque construction uses
//! `src/cheque.zig`; protocol I/O uses `src/swap.zig`. Wire-up to retrieval
//! happens in `src/p2p.zig`.

const std = @import("std");
const cheque = @import("cheque.zig");

/// Number of chunks we'll let accumulate before triggering a cheque. Slightly
/// below bee's ~25–30 chunk disconnect window so there's a margin for the
/// cheque round-trip.
pub const TRIGGER_CHUNKS: u64 = 20;

/// Wei value of each cheque we send. Set well above bee's per-chunk price
/// (~40k–540k wei depending on proximity) and above bee's announced threshold
/// (13.5M for full nodes), so bee's debt counter clears comfortably and we
/// don't churn cheques. 80% of the standard threshold = 10.8M wei.
pub const CHEQUE_AMOUNT_WEI: u256 = 10_800_000;

pub const Error = error{
    InvalidStateFile,
    OutOfMemory,
};

const PEER_OVERLAY_LEN: usize = 32;
const FILE_VERSION: u8 = 1;

/// In-memory per-peer accounting record. `last_cumulative_payout_wei` is the
/// authoritative wire value to put into the *next* cheque after incrementing
/// by `CHEQUE_AMOUNT_WEI`.
const PeerState = struct {
    overlay: [PEER_OVERLAY_LEN]u8,
    chunks_since_last_cheque: u64 = 0,
    last_cumulative_payout_wei: u256 = 0,
};

pub const Accounting = struct {
    allocator: std.mem.Allocator,
    /// Root directory for per-peer state files. We own this slice.
    root_path: []u8,
    mtx: std.Thread.Mutex = .{},
    /// peer overlay → state. Owned. Caller of openOrCreate hands us the
    /// allocator; we use it for both keys (none) and value pointers.
    map: std.AutoHashMapUnmanaged([PEER_OVERLAY_LEN]u8, *PeerState) = .{},

    /// Open or create the accounting root. Scans existing per-peer state
    /// files and rebuilds the in-memory index. Files that fail to parse are
    /// logged and skipped — they don't block startup.
    pub fn openOrCreate(allocator: std.mem.Allocator, root: []const u8) !*Accounting {
        const self = try allocator.create(Accounting);
        errdefer allocator.destroy(self);

        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);

        std.fs.cwd().makePath(owned_root) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        self.* = .{
            .allocator = allocator,
            .root_path = owned_root,
        };

        try self.scanIndex();
        return self;
    }

    pub fn deinit(self: *Accounting) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.allocator.destroy(v.*);
        self.map.deinit(self.allocator);
        self.allocator.free(self.root_path);
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

    /// Build the next cheque for `peer`, with cumulativePayout incremented by
    /// `CHEQUE_AMOUNT_WEI`. Persists the new cumulative *before* returning,
    /// so if the caller crashes between buildCheque and sendCheque, recovery
    /// won't issue a stale (re-decreasing) cumulative value.
    ///
    /// The returned `Cheque` is unsigned; caller signs with the chequebook
    /// owner's private key and ships via `swap.sendCheque`.
    pub fn buildCheque(
        self: *Accounting,
        peer: [PEER_OVERLAY_LEN]u8,
        chequebook: [20]u8,
        beneficiary: [20]u8,
    ) !cheque.Cheque {
        self.mtx.lock();
        defer self.mtx.unlock();

        const ps = try self.getOrCreate(peer);
        const new_cumulative = ps.last_cumulative_payout_wei + CHEQUE_AMOUNT_WEI;

        // Persist BEFORE returning so a crash mid-send won't issue a duplicate
        // cumulative on retry.
        try self.writeStateFileLocked(ps.overlay, new_cumulative);
        ps.last_cumulative_payout_wei = new_cumulative;

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

    // ---- internals --------------------------------------------------------

    fn getOrCreate(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8) !*PeerState {
        if (self.map.get(peer)) |ps| return ps;
        const ps = try self.allocator.create(PeerState);
        errdefer self.allocator.destroy(ps);
        ps.* = .{ .overlay = peer };
        try self.map.put(self.allocator, peer, ps);
        return ps;
    }

    /// Build the on-disk state-file path for a peer. Caller frees.
    fn statePathLocked(self: *Accounting, peer: [PEER_OVERLAY_LEN]u8) ![]u8 {
        var hex: [PEER_OVERLAY_LEN * 2]u8 = undefined;
        const hex_str = std.fmt.bytesToHex(peer, .lower);
        @memcpy(&hex, &hex_str);
        return std.fs.path.join(self.allocator, &.{ self.root_path, hex_str[0..] });
    }

    fn writeStateFileLocked(
        self: *Accounting,
        peer: [PEER_OVERLAY_LEN]u8,
        cumulative: u256,
    ) !void {
        const path = try self.statePathLocked(peer);
        defer self.allocator.free(path);

        // JSON body: {"peer_overlay":"<hex>","last_cumulative_payout_wei":"<dec>"}
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"peer_overlay\":\"");
        const hex_str = std.fmt.bytesToHex(peer, .lower);
        try body.appendSlice(self.allocator, &hex_str);
        try body.appendSlice(self.allocator, "\",\"last_cumulative_payout_wei\":\"");
        var dec_buf: [78]u8 = undefined;
        const dec = formatU256Decimal(cumulative, &dec_buf);
        try body.appendSlice(self.allocator, dec);
        try body.appendSlice(self.allocator, "\"}\n");

        try atomicWrite(self.allocator, path, body.items);
    }

    fn scanIndex(self: *Accounting) !void {
        var dir = std.fs.cwd().openDir(self.root_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len != PEER_OVERLAY_LEN * 2) continue;
            var overlay: [PEER_OVERLAY_LEN]u8 = undefined;
            _ = std.fmt.hexToBytes(&overlay, entry.name) catch continue;

            self.loadStateFile(&dir, entry.name, overlay) catch |e| {
                std.debug.print(
                    "[accounting] skipping unreadable state {s}: {any}\n",
                    .{ entry.name, e },
                );
                continue;
            };
        }
    }

    fn loadStateFile(
        self: *Accounting,
        dir: *std.fs.Dir,
        name: []const u8,
        overlay: [PEER_OVERLAY_LEN]u8,
    ) !void {
        const f = try dir.openFile(name, .{});
        defer f.close();
        const data = try f.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(data);

        const last_cumulative = try parseLastCumulative(data);

        const ps = try self.allocator.create(PeerState);
        errdefer self.allocator.destroy(ps);
        ps.* = .{
            .overlay = overlay,
            .chunks_since_last_cheque = 0,
            .last_cumulative_payout_wei = last_cumulative,
        };
        try self.map.put(self.allocator, overlay, ps);
    }
};

/// Parse `last_cumulative_payout_wei` out of the JSON body. Tolerates either a
/// quoted string (produced by us) or an unquoted number (defensive — bee's
/// own state files use unquoted, future-compat).
fn parseLastCumulative(data: []const u8) !u256 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch
        return Error.InvalidStateFile;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidStateFile;
    const obj = parsed.value.object;
    const val = obj.get("last_cumulative_payout_wei") orelse return Error.InvalidStateFile;

    return switch (val) {
        .string => |s| parseU256Decimal(s) catch return Error.InvalidStateFile,
        .integer => |n| if (n < 0) return Error.InvalidStateFile else @intCast(n),
        .number_string => |s| parseU256Decimal(s) catch return Error.InvalidStateFile,
        else => Error.InvalidStateFile,
    };
}

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

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "accounting: charge below trigger does not signal issue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const acc = try Accounting.openOrCreate(testing.allocator, root);
    defer acc.deinit();

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xAA);

    // Charge 5, 5, 5 = 15 chunks. Below the 20-chunk trigger.
    try testing.expect(!try acc.charge(peer, 5));
    try testing.expect(!try acc.charge(peer, 5));
    try testing.expect(!try acc.charge(peer, 5));

    const snap = acc.snapshot(peer).?;
    try testing.expectEqual(@as(u64, 15), snap.chunks_since_last_cheque);
    try testing.expectEqual(@as(u256, 0), snap.last_cumulative_payout_wei);
}

test "accounting: trigger at TRIGGER_CHUNKS, buildCheque advances cumulative" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const acc = try Accounting.openOrCreate(testing.allocator, root);
    defer acc.deinit();

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xBB);

    // Charge enough to trigger.
    try testing.expect(!try acc.charge(peer, TRIGGER_CHUNKS - 1));
    try testing.expect(try acc.charge(peer, 1));

    const chequebook = [_]u8{0xCB} ** 20;
    const beneficiary = [_]u8{0xBE} ** 20;

    // First cheque: cumulative = 0 + CHEQUE_AMOUNT_WEI.
    const c1 = try acc.buildCheque(peer, chequebook, beneficiary);
    try testing.expectEqual(CHEQUE_AMOUNT_WEI, c1.cumulative_payout);
    try testing.expectEqualSlices(u8, &chequebook, &c1.chequebook);
    try testing.expectEqualSlices(u8, &beneficiary, &c1.beneficiary);

    acc.markChequeSent(peer);
    const snap1 = acc.snapshot(peer).?;
    try testing.expectEqual(@as(u64, 0), snap1.chunks_since_last_cheque);
    try testing.expectEqual(CHEQUE_AMOUNT_WEI, snap1.last_cumulative_payout_wei);

    // Second cheque: cumulative grows monotonically.
    _ = try acc.charge(peer, TRIGGER_CHUNKS);
    const c2 = try acc.buildCheque(peer, chequebook, beneficiary);
    try testing.expectEqual(2 * CHEQUE_AMOUNT_WEI, c2.cumulative_payout);
}

test "accounting: state survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var peer: [32]u8 = undefined;
    @memset(&peer, 0xCC);

    {
        const acc = try Accounting.openOrCreate(testing.allocator, root);
        defer acc.deinit();
        _ = try acc.charge(peer, TRIGGER_CHUNKS);
        const chequebook = [_]u8{0xCB} ** 20;
        const beneficiary = [_]u8{0xBE} ** 20;
        _ = try acc.buildCheque(peer, chequebook, beneficiary);
        acc.markChequeSent(peer);
    }

    {
        const acc = try Accounting.openOrCreate(testing.allocator, root);
        defer acc.deinit();
        const snap = acc.snapshot(peer).?;
        // chunks_since_last_cheque is in-memory only; resets to 0 on reopen.
        try testing.expectEqual(@as(u64, 0), snap.chunks_since_last_cheque);
        // last_cumulative_payout_wei is persistent and must round-trip.
        try testing.expectEqual(CHEQUE_AMOUNT_WEI, snap.last_cumulative_payout_wei);
    }
}

test "accounting: per-peer state is isolated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const acc = try Accounting.openOrCreate(testing.allocator, root);
    defer acc.deinit();

    var p1: [32]u8 = undefined;
    @memset(&p1, 0x11);
    var p2: [32]u8 = undefined;
    @memset(&p2, 0x22);

    const cb = [_]u8{0xCB} ** 20;
    const be = [_]u8{0xBE} ** 20;

    _ = try acc.charge(p1, TRIGGER_CHUNKS);
    _ = try acc.buildCheque(p1, cb, be);
    acc.markChequeSent(p1);

    _ = try acc.charge(p2, 5);

    const s1 = acc.snapshot(p1).?;
    const s2 = acc.snapshot(p2).?;
    try testing.expectEqual(CHEQUE_AMOUNT_WEI, s1.last_cumulative_payout_wei);
    try testing.expectEqual(@as(u256, 0), s2.last_cumulative_payout_wei);
    try testing.expectEqual(@as(u64, 5), s2.chunks_since_last_cheque);
}
