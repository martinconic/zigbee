// In-memory peer table.
//
// Two indexes over the same set of `PeerEntry` values:
//   - hashmap by 32-byte overlay (for membership / lookup),
//   - 32 Kademlia bins, each a small list, for closest-peer queries.
//
// The bin index for a peer is its "proximity order" with respect to OUR
// overlay: the number of leading bits the two addresses share. Bin 0 holds
// peers with no shared leading bit (≈ half the address space); bin 31 holds
// peers that share all 32 bytes' worth of leading bits with us (i.e. our
// closest neighbours). The Swarm convention uses MaxBins = 32.
//
// We keep this dumb on purpose: each bin is a slice, no eviction yet, no
// stale-detection. Phase 3 just needs "what peers do we know about" + "find
// the closest peer to a chunk address" — Phase 4 (retrieval) is the only
// caller. Eviction and replacement become important once we run for hours
// or get rate-limited.

const std = @import("std");
const bzz_address = @import("bzz_address.zig");

pub const MAX_BINS: usize = 32;

pub const Error = error{
    OutOfMemory,
};

pub const PeerEntry = struct {
    overlay: [bzz_address.OVERLAY_LEN]u8,
    eth_address: [bzz_address.ETH_ADDR_LEN]u8,
    full_node: bool,
    /// Concatenated underlay blob (bee's serialized form — single multiaddr
    /// or 0x99-prefixed list). Allocator-owned.
    underlay: []u8,
    /// Bin we placed this peer in (cached for cheap removal/diagnostics).
    bin: u5,

    fn deinit(self: PeerEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.underlay);
    }
};

pub const PeerTable = struct {
    allocator: std.mem.Allocator,
    /// Our own overlay — used to compute the proximity-order bin for each peer.
    own_overlay: [bzz_address.OVERLAY_LEN]u8,
    /// `peers` owns each entry's memory; bins[*] hold pointers back into the
    /// hash-map's stored values (we keep the table small and don't move
    /// entries, so these pointers are stable).
    peers: std.AutoHashMap([bzz_address.OVERLAY_LEN]u8, PeerEntry),
    bins: [MAX_BINS]std.ArrayList([bzz_address.OVERLAY_LEN]u8),

    pub fn init(allocator: std.mem.Allocator, own_overlay: [bzz_address.OVERLAY_LEN]u8) PeerTable {
        return .{
            .allocator = allocator,
            .own_overlay = own_overlay,
            .peers = std.AutoHashMap([bzz_address.OVERLAY_LEN]u8, PeerEntry).init(allocator),
            .bins = [_]std.ArrayList([bzz_address.OVERLAY_LEN]u8){.{}} ** MAX_BINS,
        };
    }

    pub fn deinit(self: *PeerTable) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.peers.deinit();
        for (&self.bins) |*bin| bin.deinit(self.allocator);
    }

    /// Adds (or refreshes) a peer entry. Takes ownership of `underlay`.
    /// If the overlay was already in the table, the previous underlay is
    /// freed and replaced. Self-overlay (== own_overlay) is silently
    /// ignored — bee includes us in its own broadcasts sometimes, no
    /// reason to track ourselves.
    pub fn upsert(
        self: *PeerTable,
        overlay: [bzz_address.OVERLAY_LEN]u8,
        eth_address: [bzz_address.ETH_ADDR_LEN]u8,
        full_node: bool,
        underlay: []u8,
    ) !void {
        if (std.mem.eql(u8, &overlay, &self.own_overlay)) {
            self.allocator.free(underlay);
            return;
        }
        const bin_idx = proximityOrder(self.own_overlay, overlay);
        const new_entry = PeerEntry{
            .overlay = overlay,
            .eth_address = eth_address,
            .full_node = full_node,
            .underlay = underlay,
            .bin = bin_idx,
        };

        if (self.peers.fetchRemove(overlay)) |old| {
            // Replace: free the old underlay, leave the bin entry as-is
            // (overlay is the same bin index regardless of underlay).
            old.value.deinit(self.allocator);
        } else {
            try self.bins[bin_idx].append(self.allocator, overlay);
        }
        try self.peers.put(overlay, new_entry);
    }

    pub fn get(self: *const PeerTable, overlay: [bzz_address.OVERLAY_LEN]u8) ?PeerEntry {
        return self.peers.get(overlay);
    }

    pub fn count(self: *const PeerTable) usize {
        return self.peers.count();
    }

    /// Walks every bin starting from `target`'s proximity order downwards
    /// and finds the peer with the lowest XOR distance to `target`.
    /// Returns null when the table is empty.
    pub fn closestTo(self: *const PeerTable, target: [bzz_address.OVERLAY_LEN]u8) ?PeerEntry {
        if (self.peers.count() == 0) return null;

        const start_bin = proximityOrder(self.own_overlay, target);

        // Try the start bin first, then ripple outwards (start ± 1, ± 2, …).
        // For a small table we could just scan all peers; the bin walk is a
        // small optimisation that scales to thousands of peers.
        var best_overlay: ?[bzz_address.OVERLAY_LEN]u8 = null;
        var best_distance: [bzz_address.OVERLAY_LEN]u8 = [_]u8{0xFF} ** bzz_address.OVERLAY_LEN;

        for (self.bins[start_bin].items) |ov| {
            const d = xorDistance(ov, target);
            if (cmpBE(&d, &best_distance) < 0) {
                best_overlay = ov;
                best_distance = d;
            }
        }
        // Ripple outwards: at distance bin±k from start.
        var k: usize = 1;
        while (k < MAX_BINS) : (k += 1) {
            if (start_bin >= k) {
                const lower: u5 = @intCast(start_bin - k);
                for (self.bins[lower].items) |ov| {
                    const d = xorDistance(ov, target);
                    if (cmpBE(&d, &best_distance) < 0) {
                        best_overlay = ov;
                        best_distance = d;
                    }
                }
            }
            if (start_bin + k < MAX_BINS) {
                const upper: u5 = @intCast(start_bin + k);
                for (self.bins[upper].items) |ov| {
                    const d = xorDistance(ov, target);
                    if (cmpBE(&d, &best_distance) < 0) {
                        best_overlay = ov;
                        best_distance = d;
                    }
                }
            }
        }
        if (best_overlay) |ov| return self.peers.get(ov);
        return null;
    }

    /// Returns peer counts indexed by bin.
    pub fn binDepths(self: *const PeerTable) [MAX_BINS]usize {
        var out: [MAX_BINS]usize = undefined;
        for (self.bins, 0..) |bin, i| out[i] = bin.items.len;
        return out;
    }
};

/// Number of leading bits two 32-byte addresses share. Returned as a u5 so
/// it can index `bins[]` directly. Capped at MAX_BINS - 1 = 31 for the
/// extreme case where the addresses are identical.
fn proximityOrder(a: [bzz_address.OVERLAY_LEN]u8, b: [bzz_address.OVERLAY_LEN]u8) u5 {
    var po: usize = 0;
    var i: usize = 0;
    while (i < bzz_address.OVERLAY_LEN) : (i += 1) {
        const x = a[i] ^ b[i];
        if (x == 0) {
            po += 8;
            continue;
        }
        // Count leading zeros in the byte (MSB first).
        var bit: u3 = 7;
        while (true) {
            if ((x >> bit) & 1 == 1) break;
            po += 1;
            if (bit == 0) break;
            bit -= 1;
        }
        break;
    }
    if (po >= MAX_BINS) po = MAX_BINS - 1;
    return @intCast(po);
}

fn xorDistance(a: [bzz_address.OVERLAY_LEN]u8, b: [bzz_address.OVERLAY_LEN]u8) [bzz_address.OVERLAY_LEN]u8 {
    var out: [bzz_address.OVERLAY_LEN]u8 = undefined;
    for (a, b, 0..) |x, y, i| out[i] = x ^ y;
    return out;
}

fn cmpBE(a: *const [bzz_address.OVERLAY_LEN]u8, b: *const [bzz_address.OVERLAY_LEN]u8) i8 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ---------- tests ----------

const testing = std.testing;

test "proximityOrder: identical and disjoint" {
    const a: [32]u8 = [_]u8{0xFF} ** 32;
    try testing.expectEqual(@as(u5, MAX_BINS - 1), proximityOrder(a, a));

    const b: [32]u8 = [_]u8{0x00} ** 32;
    // 0xFF ^ 0x00 = 0xFF — first byte's MSB differs immediately, po = 0.
    try testing.expectEqual(@as(u5, 0), proximityOrder(a, b));
}

test "proximityOrder: matches a few hand-computed cases" {
    var a: [32]u8 = [_]u8{0} ** 32;
    var b: [32]u8 = [_]u8{0} ** 32;

    // Differ in the LSB of the first byte: 7 leading zero bits agree.
    a[0] = 0b00000000;
    b[0] = 0b00000001;
    try testing.expectEqual(@as(u5, 7), proximityOrder(a, b));

    // Differ in the second byte: 8 leading bits agree.
    a[0] = 0xAA;
    b[0] = 0xAA;
    a[1] = 0x00;
    b[1] = 0x80; // MSB of byte 1 differs → po = 8
    try testing.expectEqual(@as(u5, 8), proximityOrder(a, b));

    // Match all 32 bytes — clamp to MAX_BINS - 1.
    @memset(&b, 0xAA);
    @memset(&a, 0xAA);
    try testing.expectEqual(@as(u5, MAX_BINS - 1), proximityOrder(a, b));
}

test "PeerTable: upsert + closestTo basic flow" {
    const own: [32]u8 = [_]u8{0} ** 32;
    var table = PeerTable.init(testing.allocator, own);
    defer table.deinit();

    // Add three peers with addresses 0x80…, 0x40…, 0x01…
    var p1: [32]u8 = [_]u8{0} ** 32;
    p1[0] = 0x80;
    var p2: [32]u8 = [_]u8{0} ** 32;
    p2[0] = 0x40;
    var p3: [32]u8 = [_]u8{0} ** 32;
    p3[0] = 0x01;

    const eth_zero: [bzz_address.ETH_ADDR_LEN]u8 = [_]u8{0} ** bzz_address.ETH_ADDR_LEN;

    try table.upsert(p1, eth_zero, true, try testing.allocator.dupe(u8, "u1"));
    try table.upsert(p2, eth_zero, true, try testing.allocator.dupe(u8, "u2"));
    try table.upsert(p3, eth_zero, false, try testing.allocator.dupe(u8, "u3"));
    try testing.expectEqual(@as(usize, 3), table.count());

    // Target 0x10… is closest to p3 (0x01…) by XOR.
    var target: [32]u8 = [_]u8{0} ** 32;
    target[0] = 0x10;
    const closest = table.closestTo(target) orelse return error.NoneFound;
    try testing.expectEqualSlices(u8, &p3, &closest.overlay);
}

test "PeerTable: self-overlay is ignored" {
    const own: [32]u8 = [_]u8{0xAA} ** 32;
    var table = PeerTable.init(testing.allocator, own);
    defer table.deinit();
    try table.upsert(own, [_]u8{0} ** 20, true, try testing.allocator.dupe(u8, "self-loop"));
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "PeerTable: upsert replaces rather than duplicates" {
    const own: [32]u8 = [_]u8{0} ** 32;
    var table = PeerTable.init(testing.allocator, own);
    defer table.deinit();

    var p: [32]u8 = [_]u8{0} ** 32;
    p[0] = 0x42;
    try table.upsert(p, [_]u8{0} ** 20, true, try testing.allocator.dupe(u8, "first"));
    try table.upsert(p, [_]u8{0} ** 20, false, try testing.allocator.dupe(u8, "second"));
    try testing.expectEqual(@as(usize, 1), table.count());
    const e = table.get(p) orelse return error.MissingEntry;
    try testing.expectEqualSlices(u8, "second", e.underlay);
    try testing.expectEqual(false, e.full_node);
}
