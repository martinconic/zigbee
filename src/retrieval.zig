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
// We content-validate the returned bytes: try CAC first (BMT-derived
// address), then fall back to SOC validation (`keccak256(id ‖ owner)`).
// If neither matches the requested address, the peer returned the wrong
// chunk — surface as `ChunkAddressMismatch` rather than passing the
// bytes through unverified.

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");
const swarm_proto = @import("swarm_proto.zig");
const bmt = @import("bmt.zig");
const soc = @import("soc.zig");
const identity = @import("identity.zig");

pub const PROTOCOL_ID = "/swarm/retrieval/1.4.0/retrieval";
const MAX_CHUNK_BYTES: usize = 4096 + 8 + 1024; // ChunkSize + SpanSize + slack

pub const Error = error{
    PeerError,
    ChunkAddressMismatch,
    EmptyDelivery,
};

pub const RetrievedChunk = struct {
    /// Inner payload bytes (no 8-byte span prefix). For a CAC, this is
    /// the bytes the BMT was computed over. For a SOC, this is the
    /// payload of the wrapped CAC — i.e., the bytes the SOC's owner
    /// stored. Callers that don't care about CAC vs SOC just consume
    /// `data`; callers that do (feed readers, future) inspect `is_soc`.
    data: []u8,
    /// 8-byte span (inner payload length / subtree size, little-endian uint64).
    span: u64,
    /// 32-byte address — equal to the address the caller requested.
    address: [bmt.HASH_SIZE]u8,
    /// Allocator-owned stamp blob, possibly empty if the responder
    /// didn't attach one. Stamp validation is 0.6 work.
    stamp: []u8,
    /// True iff the chunk validated as a SOC rather than a CAC.
    is_soc: bool = false,
    /// SOC identifier (`keccak256(id ‖ owner)` = `address`). Only
    /// meaningful when `is_soc == true`.
    soc_id: [soc.ID_SIZE]u8 = [_]u8{0} ** soc.ID_SIZE,
    /// Recovered SOC owner eth address. Only meaningful when `is_soc == true`.
    soc_owner: [identity.ETHEREUM_ADDRESS_SIZE]u8 =
        [_]u8{0} ** identity.ETHEREUM_ADDRESS_SIZE,

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

    // Try CAC first. The wire `Data` field for a CAC is `span(8) || payload`.
    // Intermediate chunks of a chunk-tree carry `span = total subtree size`,
    // not `payload.len`, so we must use the span we read off the wire —
    // `bmt.Chunk.init` would default to `payload.len` and break intermediates.
    const cac_span = std.mem.readInt(u64, data[0..bmt.SPAN_SIZE], .little);
    const cac_payload = data[bmt.SPAN_SIZE..];

    var cac_match = false;
    var cac_err_too_large = false;
    if (cac_payload.len <= bmt.CHUNK_SIZE) {
        var chunk = bmt.Chunk.init(cac_payload);
        chunk.span = cac_span;
        var cac_derived: [bmt.HASH_SIZE]u8 = undefined;
        chunk.address(&cac_derived) catch {
            // bmt.Error.ChunkDataTooLarge — fall through to SOC.
            cac_err_too_large = true;
        };
        if (!cac_err_too_large and std.mem.eql(u8, &cac_derived, &chunk_address))
            cac_match = true;
    }

    if (cac_match) {
        const data_owned = try allocator.dupe(u8, cac_payload);
        errdefer allocator.free(data_owned);
        const stamp_owned = try allocator.dupe(u8, stamp);
        return RetrievedChunk{
            .data = data_owned,
            .span = cac_span,
            .address = chunk_address,
            .stamp = stamp_owned,
            ._allocator = allocator,
        };
    }

    // Try SOC. For a SOC, the wire `Data` field is
    // `id(32) ‖ sig(65) ‖ span(8) ‖ payload`, and the address the
    // caller asked for is `keccak256(id ‖ recovered_owner_eth_addr)`.
    if (soc.parseAndValidate(data, chunk_address)) |s| {
        const data_owned = try allocator.dupe(u8, s.payload);
        errdefer allocator.free(data_owned);
        const stamp_owned = try allocator.dupe(u8, stamp);
        return RetrievedChunk{
            .data = data_owned,
            .span = s.span,
            .address = chunk_address,
            .stamp = stamp_owned,
            .is_soc = true,
            .soc_id = s.id,
            .soc_owner = s.owner,
            ._allocator = allocator,
        };
    } else |soc_err| {
        // Neither CAC nor SOC matches. The peer either corrupted the
        // bytes or returned a different chunk than we asked for.
        std.debug.print(
            "[retrieval] address mismatch for {s}: cac={s} soc_err={any} bytes={d}\n",
            .{
                std.fmt.bytesToHex(chunk_address, .lower),
                if (cac_err_too_large) "(too-large)" else "(no-match)",
                soc_err,
                data.len,
            },
        );
        return Error.ChunkAddressMismatch;
    }
}
