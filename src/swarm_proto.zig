// Shared wire helpers for bee /swarm/* application protocols.
//
//   - Varint-delimited protobuf framing (every message on every stream is
//     prefixed with a varint length).
//   - Bee's "headers exchange": peer writes Headers { headers: [] }, we
//     write Headers { headers: [] } back. Required at the start of every
//     /swarm/* stream EXCEPT the bzz handshake itself. Empty headers are
//     fine for everything we currently handle (bee uses headers mostly for
//     tracing context and per-stream parameters like exchange-rate
//     announcements that we don't yet care about).

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");

pub const Error = error{
    EndOfStream,
    VarintTooLong,
    MessageTooLarge,
};

const DEFAULT_MAX_MSG_SIZE: usize = 128 * 1024;

/// Reads a varint length prefix + that many bytes. Returns a heap-owned
/// slice; caller frees.
pub fn readDelimited(allocator: std.mem.Allocator, stream: *yamux.Stream, max_size: usize) ![]u8 {
    var len_byte: [1]u8 = undefined;
    var len: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const n = try stream.read(&len_byte);
        if (n == 0) return Error.EndOfStream;
        const b = len_byte[0];
        len |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        if (shift == 63) return Error.VarintTooLong;
        shift += 7;
    } else return Error.VarintTooLong;

    if (len > max_size) return Error.MessageTooLarge;
    const ulen: usize = @intCast(len);
    const buf = try allocator.alloc(u8, ulen);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < ulen) {
        const n = try stream.read(buf[off..]);
        if (n == 0) return Error.EndOfStream;
        off += n;
    }
    return buf;
}

/// Writes a varint length prefix + payload.
pub fn writeDelimited(stream: *yamux.Stream, payload: []const u8) !void {
    var len_buf: [10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&len_buf);
    try proto.writeVarint(fbs.writer(), payload.len);
    try stream.writeAll(fbs.getWritten());
    if (payload.len > 0) try stream.writeAll(payload);
}

/// Performs bee's per-stream Headers exchange — RESPONDER side. We're
/// accepting an inbound stream, so the peer writes their headers first
/// and waits for ours.
///   1. Read peer's Headers (any content — we discard it).
///   2. Write back an empty `Headers { headers: [] }` (a single 0x00 byte).
pub fn exchangeEmptyHeaders(allocator: std.mem.Allocator, stream: *yamux.Stream) !void {
    const peer_headers = try readDelimited(allocator, stream, 4096);
    allocator.free(peer_headers);
    try stream.writeAll(&[_]u8{0x00});
}

/// Same exchange, but INITIATOR side. We're opening the stream, so we
/// write our (empty) headers first and then read the peer's. Order is
/// flipped vs. exchangeEmptyHeaders — bee's headers.go:sendHeaders does
/// write-then-read on the initiator, read-then-write on the responder.
pub fn exchangeEmptyHeadersInitiator(allocator: std.mem.Allocator, stream: *yamux.Stream) !void {
    try stream.writeAll(&[_]u8{0x00});
    const peer_headers = try readDelimited(allocator, stream, 4096);
    allocator.free(peer_headers);
}
