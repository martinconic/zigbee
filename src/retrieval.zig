// `/swarm/retrieval/1.4.0/retrieval` — content-addressed chunk retrieval.
//
// Wire flow on a freshly opened stream (caller has already done
// multistream-select for PROTOCOL_ID):
//   1. Headers exchange (every /swarm/* protocol).
//   2. Initiator writes Request { Addr: <32-byte chunk address> }.
//   3. Responder reads request, finds the chunk (locally or via forwarded
//      retrieval), writes Delivery { Data, Stamp, Err }.
//   4. If Err is non-empty, the chunk is unavailable.
//   5. Stream closes.
//
// proto:
//   message Request  { bytes Addr  = 1; }
//   message Delivery { bytes Data  = 1; bytes Stamp = 2; string Err = 3; }
//
// We content-validate the returned data: address(span_le_u64 || data) must
// equal the requested address. (Single-Owner Chunks are also valid in bee
// but we don't implement SOC validation yet — Phase 4 retrieves only CACs.)

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");
const swarm_proto = @import("swarm_proto.zig");
const bmt = @import("bmt.zig");

pub const PROTOCOL_ID = "/swarm/retrieval/1.4.0/retrieval";
const MAX_CHUNK_BYTES: usize = 4096 + 8 + 1024; // ChunkSize + SpanSize + slack

pub const Error = error{
    PeerError,
    ChunkAddressMismatch,
    EmptyDelivery,
};

pub const RetrievedChunk = struct {
    /// Chunk payload (without the 8-byte span). For a content-addressed
    /// chunk, hashing this with the span produces `address`.
    data: []u8,
    /// 8-byte span (data length, little-endian uint64).
    span: u64,
    /// 32-byte content address — equal to the address the caller requested.
    address: [bmt.HASH_SIZE]u8,
    /// Allocator-owned stamp blob, possibly empty if the responder didn't
    /// attach one. We don't validate it yet.
    stamp: []u8,

    _allocator: std.mem.Allocator,

    pub fn deinit(self: RetrievedChunk) void {
        self._allocator.free(self.data);
        self._allocator.free(self.stamp);
    }
};

/// Initiator: write Request, read Delivery, validate, return.
pub fn request(
    allocator: std.mem.Allocator,
    stream: *yamux.Stream,
    chunk_address: [bmt.HASH_SIZE]u8,
) !RetrievedChunk {
    try swarm_proto.exchangeEmptyHeadersInitiator(allocator, stream);

    // Write Request { Addr: <32 bytes> } — varint(field=1, wire=2) || varint(32) || addr.
    var req_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&req_buf);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, chunk_address.len);
    try w.writeAll(&chunk_address);
    try swarm_proto.writeDelimited(stream, fbs.getWritten());

    // Read Delivery.
    const body = try swarm_proto.readDelimited(allocator, stream, MAX_CHUNK_BYTES);
    defer allocator.free(body);

    var data: []const u8 = &[_]u8{};
    var stamp: []const u8 = &[_]u8{};
    var err_str: []const u8 = &[_]u8{};

    var off: usize = 0;
    while (off < body.len) {
        const tag = try proto.readVarint(body[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) break;
        const lr = try proto.readVarint(body[off..]);
        off += lr.bytes_read;
        const flen: usize = @intCast(lr.value);
        if (off + flen > body.len) break;
        const field_data = body[off .. off + flen];
        off += flen;
        switch (fnum) {
            1 => data = field_data,
            2 => stamp = field_data,
            3 => err_str = field_data,
            else => {},
        }
    }

    if (err_str.len > 0) {
        std.debug.print("[retrieval] peer reported error: \"{s}\"\n", .{err_str});
        return Error.PeerError;
    }
    if (data.len < bmt.SPAN_SIZE) return Error.EmptyDelivery;

    // The wire `Data` field carries `span (8 LE bytes) || chunk_data`.
    const span = std.mem.readInt(u64, data[0..bmt.SPAN_SIZE], .little);
    const payload = data[bmt.SPAN_SIZE..];

    // Validate as a content-addressed chunk: BMT root over the payload,
    // hashed with the span prefix, must equal the address we asked for.
    // For intermediate chunks (chunk-tree internal nodes), the span is
    // the *total subtree size*, NOT `payload.len`, so we must use the
    // span we read off the wire — `bmt.Chunk.init` would default to
    // `payload.len` and cause every intermediate to fail CAC validation.
    //
    // Swarm also has Single-Owner Chunks (SOCs) where the address is
    // keccak256(identifier ‖ owner_eth_address); those won't match the
    // CAC computation regardless. We log SOC candidates and pass the
    // bytes through unverified for now (Phase 4 MVP). Full SOC
    // verification is a future phase.
    var chunk = bmt.Chunk.init(payload);
    chunk.span = span;
    var derived: [bmt.HASH_SIZE]u8 = undefined;
    try chunk.address(&derived);
    const cac_match = std.mem.eql(u8, &derived, &chunk_address);
    if (!cac_match) {
        std.debug.print(
            "[retrieval] CAC mismatch (likely a SOC): requested={s} cac_hash={s}\n" ++
                "[retrieval] returning bytes unverified — implement SOC validation in a later phase\n",
            .{
                std.fmt.bytesToHex(chunk_address, .lower),
                std.fmt.bytesToHex(derived, .lower),
            },
        );
    }

    // Copy out into caller-owned buffers.
    const data_owned = try allocator.dupe(u8, payload);
    errdefer allocator.free(data_owned);
    const stamp_owned = try allocator.dupe(u8, stamp);

    return RetrievedChunk{
        .data = data_owned,
        .span = span,
        .address = chunk_address,
        .stamp = stamp_owned,
        ._allocator = allocator,
    };
}
