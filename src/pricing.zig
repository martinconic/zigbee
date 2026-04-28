// `/swarm/pricing/1.0.0/pricing` — minimal stub responder.
//
// One-shot wire flow (after multistream-select):
//   1. Bee writes Headers { headers: [] } (varint-delimited protobuf).
//   2. We write the same back.
//   3. Bee writes AnnouncePaymentThreshold { PaymentThreshold: bytes }.
//   4. Stream closes.
//
// We don't act on the threshold yet (we'd settle in BZZ via chequebooks if
// we were a full node). Read-and-discard keeps bee from disconnecting us.

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");
const swarm_proto = @import("swarm_proto.zig");

pub const PROTOCOL_ID = "/swarm/pricing/1.0.0/pricing";

pub fn respond(allocator: std.mem.Allocator, stream: *yamux.Stream) !void {
    try swarm_proto.exchangeEmptyHeaders(allocator, stream);
    const buf = try swarm_proto.readDelimited(allocator, stream, 1024);
    defer allocator.free(buf);

    var threshold_bytes: []const u8 = &[_]u8{};
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
        if (fnum == 1) threshold_bytes = buf[off .. off + flen];
        off += flen;
    }

    std.debug.print("[pricing] peer payment threshold: {d} bytes\n", .{threshold_bytes.len});
}

/// Initiator: open a fresh stream (caller does that + multistream-select),
/// then announce OUR payment threshold to bee. Bee's accounting refuses
/// outbound work (e.g. retrieval) until we've sent this — it tracks us as
/// "connection not initialized yet" otherwise.
///
/// `threshold_be` is the big-endian unsigned-int representation of the
/// threshold (matches bee's wire encoding).
pub fn announce(allocator: std.mem.Allocator, stream: *yamux.Stream, threshold_be: []const u8) !void {
    try swarm_proto.exchangeEmptyHeadersInitiator(allocator, stream);

    // Build AnnouncePaymentThreshold { PaymentThreshold: <bytes> }.
    var msg_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg_buf);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, threshold_be.len);
    try w.writeAll(threshold_be);
    try swarm_proto.writeDelimited(stream, fbs.getWritten());
}
