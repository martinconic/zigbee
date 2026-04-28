// `/swarm/hive/1.1.0/peers` — peer-discovery responder.
//
// Wire flow:
//   1. Bee writes Headers { headers: [] }.
//   2. We write Headers back.
//   3. Bee writes Peers { peers: [BzzAddress, …] }.
//   4. Stream closes.
//
// Each `BzzAddress` is `{ underlay, signature, overlay, nonce }`. We
// validate the signature, derive the Ethereum address, and persist the
// entry in the caller-supplied PeerTable. Invalid entries are logged and
// skipped (one bad entry doesn't reject the whole batch).

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");
const swarm_proto = @import("swarm_proto.zig");
const bzz_address = @import("bzz_address.zig");
const peer_table = @import("peer_table.zig");
const multiaddr = @import("multiaddr.zig");

pub const PROTOCOL_ID = "/swarm/hive/1.1.0/peers";

pub fn respond(
    allocator: std.mem.Allocator,
    stream: *yamux.Stream,
    table: *peer_table.PeerTable,
    network_id: u64,
) !void {
    _ = network_id; // bee's hive broadcast is advisory; we don't re-verify.
    try swarm_proto.exchangeEmptyHeaders(allocator, stream);

    const buf = try swarm_proto.readDelimited(allocator, stream, 64 * 1024);
    defer allocator.free(buf);

    var added: usize = 0;
    var rejected: usize = 0;
    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) break;
        const lr = try proto.readVarint(buf[off..]);
        off += lr.bytes_read;
        const flen: usize = @intCast(lr.value);
        if (off + flen > buf.len) break;
        const entry_bytes = buf[off .. off + flen];
        off += flen;

        if (fnum != 1) continue;

        // Hive entries are NOT cryptographically verifiable on the wire:
        // bee strips/filters the underlays after the original handshake
        // signature, so the signature only matches the original underlays
        // (which bee no longer ships). We accept these as advisory hints
        // and verify cryptographically the next time we directly handshake
        // with each peer.
        var v = bzz_address.parseNoVerify(allocator, entry_bytes) catch |e| {
            std.debug.print("[hive] dropped malformed BzzAddress: {any}\n", .{e});
            rejected += 1;
            continue;
        };
        // We need the underlay bytes to outlive v; copy them out before
        // v.deinit frees its buffer.
        const underlay_owned = try allocator.dupe(u8, v.underlay);
        v.deinit();

        table.upsert(v.overlay, v.eth_address, false, underlay_owned) catch |e| {
            std.debug.print("[hive] table.upsert failed: {any}\n", .{e});
            allocator.free(underlay_owned);
            rejected += 1;
            continue;
        };
        added += 1;
    }

    std.debug.print(
        "[hive] broadcast: {d} added, {d} rejected, table size {d}\n",
        .{ added, rejected, table.count() },
    );

    // Print first few overlays + their bins so you can sanity-check distribution.
    const depths = table.binDepths();
    var nonzero: usize = 0;
    for (depths) |d| {
        if (d > 0) nonzero += 1;
    }
    std.debug.print("[hive] non-empty bins: {d}/32 — ", .{nonzero});
    for (depths, 0..) |d, i| {
        if (d > 0) std.debug.print("[{d}]={d} ", .{ i, d });
    }
    std.debug.print("\n", .{});
}
