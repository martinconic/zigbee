// libp2p Identify (`/ipfs/id/1.0.0`) responder.
//
// Wire flow on a freshly opened stream:
//   1. Both sides do multistream-select for `/ipfs/id/1.0.0` (handled by the
//      caller).
//   2. Responder (us) writes ONE Identify protobuf message, varint-length
//      prefixed (the libp2p "delimited" framing).
//   3. Responder closes its end of the stream.
//
// proto from go-libp2p/p2p/protocol/identify/pb/identify.proto:
//
//   message Identify {
//       optional string protocolVersion = 5;
//       optional string agentVersion    = 6;
//       optional bytes  publicKey       = 1;   // libp2p PublicKey proto
//       repeated bytes  listenAddrs     = 2;
//       optional bytes  observedAddr    = 4;
//       repeated string protocols       = 3;
//       optional bytes  signedPeerRecord = 8;
//   }

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");

pub const PROTOCOL_ID = "/ipfs/id/1.0.0";

pub const PROTOCOL_VERSION = "ipfs/0.1.0";
pub const AGENT_VERSION = "zigbee/0.1.0";

/// Handles a single peer-initiated /ipfs/id/1.0.0 stream.
/// Caller has already read the peer's multistream hello and protocol proposal.
pub fn respond(
    stream: *yamux.Stream,
    id: *const identity.Identity,
    protocols: []const []const u8,
) !void {
    // 1. Confirm the protocol selection: write our multistream hello + the
    //    protocol the peer proposed.
    try multistream.writeMessage(stream, multistream.VERSION);
    try multistream.writeMessage(stream, PROTOCOL_ID);

    // 2. Build the Identify message.
    var msg_buf: [1024]u8 = undefined;
    var msg_fbs = std.io.fixedBufferStream(&msg_buf);
    try encodeIdentify(msg_fbs.writer(), id, protocols);
    const msg_bytes = msg_fbs.getWritten();

    // 3. Send length-prefixed (varint) on the stream.
    var len_buf: [10]u8 = undefined;
    var len_fbs = std.io.fixedBufferStream(&len_buf);
    try proto.writeVarint(len_fbs.writer(), msg_bytes.len);
    try stream.writeAll(len_fbs.getWritten());
    try stream.writeAll(msg_bytes);

    // 4. Close our half of the stream.
    try stream.close();
}

fn encodeIdentify(
    writer: anytype,
    id: *const identity.Identity,
    protocols: []const []const u8,
) !void {
    // Build our publicKey field — wire-encoded libp2p `PublicKey`:
    //   tag(field=1, varint) || key_type=2 (Secp256k1)
    //   tag(field=2, length-delim) || len || 33-byte compressed pubkey
    var pubkey_proto: [64]u8 = undefined;
    var pk_fbs = std.io.fixedBufferStream(&pubkey_proto);
    {
        var compressed: [identity.COMPRESSED_PUBKEY_SIZE]u8 = undefined;
        try id.compressedPublicKey(&compressed);
        try proto.writeVarint(pk_fbs.writer(), (1 << 3) | 0); // field 1, varint
        try proto.writeVarint(pk_fbs.writer(), 2); // KeyType.Secp256k1
        try proto.writeVarint(pk_fbs.writer(), (2 << 3) | 2); // field 2, len-delim
        try proto.writeVarint(pk_fbs.writer(), compressed.len);
        try pk_fbs.writer().writeAll(&compressed);
    }
    const pubkey_bytes = pk_fbs.getWritten();

    // Field 1: publicKey (bytes)
    try proto.writeVarint(writer, (1 << 3) | 2);
    try proto.writeVarint(writer, pubkey_bytes.len);
    try writer.writeAll(pubkey_bytes);

    // Field 3: protocols (repeated string) — one tag per entry.
    for (protocols) |p| {
        try proto.writeVarint(writer, (3 << 3) | 2);
        try proto.writeVarint(writer, p.len);
        try writer.writeAll(p);
    }

    // Field 5: protocolVersion (string)
    try proto.writeVarint(writer, (5 << 3) | 2);
    try proto.writeVarint(writer, PROTOCOL_VERSION.len);
    try writer.writeAll(PROTOCOL_VERSION);

    // Field 6: agentVersion (string)
    try proto.writeVarint(writer, (6 << 3) | 2);
    try proto.writeVarint(writer, AGENT_VERSION.len);
    try writer.writeAll(AGENT_VERSION);
}

/// Decoded Identify message. All slices borrow from `_buffer` until
/// PeerInfo.deinit is called.
pub const PeerInfo = struct {
    public_key: []const u8,
    listen_addrs: []const []const u8,
    protocols: []const []const u8,
    protocol_version: []const u8,
    agent_version: []const u8,

    _allocator: std.mem.Allocator,
    _buffer: []u8,
    _listen_addrs: [][]const u8,
    _protocols: [][]const u8,

    pub fn deinit(self: PeerInfo) void {
        self._allocator.free(self._buffer);
        self._allocator.free(self._listen_addrs);
        self._allocator.free(self._protocols);
    }

    pub fn supports(self: PeerInfo, protocol: []const u8) bool {
        for (self.protocols) |p| {
            if (std.mem.eql(u8, p, protocol)) return true;
        }
        return false;
    }
};

/// Initiator: open a stream to the peer, do multistream-select for
/// /ipfs/id/1.0.0, read the varint-delimited Identify message, decode it.
/// Caller owns the returned PeerInfo; call deinit when done.
pub fn request(allocator: std.mem.Allocator, stream: *yamux.Stream) !PeerInfo {
    try multistream.selectOne(stream, PROTOCOL_ID);

    // Read the varint length prefix one byte at a time, then the body.
    var len_byte: [1]u8 = undefined;
    var len: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const n = try stream.read(&len_byte);
        if (n == 0) return error.EndOfStream;
        const b = len_byte[0];
        len |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        if (shift == 63) return error.VarintTooLong;
        shift += 7;
    } else return error.VarintTooLong;

    if (len > 1024 * 1024) return error.MessageTooLarge;
    const body_len: usize = @intCast(len);
    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);

    var read_total: usize = 0;
    while (read_total < body_len) {
        const n = try stream.read(body[read_total..]);
        if (n == 0) return error.EndOfStream;
        read_total += n;
    }
    return decodePeerInfo(allocator, body);
}

fn decodePeerInfo(allocator: std.mem.Allocator, body: []u8) !PeerInfo {
    var public_key: []const u8 = &[_]u8{};
    var protocol_version: []const u8 = &[_]u8{};
    var agent_version: []const u8 = &[_]u8{};

    // First pass: count repeated fields so we can size the slices.
    var n_listen: usize = 0;
    var n_proto: usize = 0;
    {
        var off: usize = 0;
        while (off < body.len) {
            const tag = try proto.readVarint(body[off..]);
            off += tag.bytes_read;
            const wt = tag.value & 0x07;
            const fnum = tag.value >> 3;
            if (wt != 2) return error.InvalidProtobuf;
            const len_res = try proto.readVarint(body[off..]);
            off += len_res.bytes_read;
            const data_len: usize = @intCast(len_res.value);
            if (off + data_len > body.len) return error.BufferTooShort;
            switch (fnum) {
                2 => n_listen += 1,
                3 => n_proto += 1,
                else => {},
            }
            off += data_len;
        }
    }

    const listen_slice = try allocator.alloc([]const u8, n_listen);
    errdefer allocator.free(listen_slice);
    const proto_slice = try allocator.alloc([]const u8, n_proto);
    errdefer allocator.free(proto_slice);

    var li: usize = 0;
    var pi: usize = 0;
    var off: usize = 0;
    while (off < body.len) {
        const tag = try proto.readVarint(body[off..]);
        off += tag.bytes_read;
        const fnum = tag.value >> 3;
        const len_res = try proto.readVarint(body[off..]);
        off += len_res.bytes_read;
        const data_len: usize = @intCast(len_res.value);
        const data = body[off .. off + data_len];
        off += data_len;
        switch (fnum) {
            1 => public_key = data,
            2 => {
                listen_slice[li] = data;
                li += 1;
            },
            3 => {
                proto_slice[pi] = data;
                pi += 1;
            },
            5 => protocol_version = data,
            6 => agent_version = data,
            else => {}, // observedAddr (4) and signedPeerRecord (8) ignored
        }
    }

    return PeerInfo{
        .public_key = public_key,
        .listen_addrs = listen_slice,
        .protocols = proto_slice,
        .protocol_version = protocol_version,
        .agent_version = agent_version,
        ._allocator = allocator,
        ._buffer = body,
        ._listen_addrs = listen_slice,
        ._protocols = proto_slice,
    };
}

// ---- tests ----

test "identify message round-trips through our own decoder" {
    const id = try identity.Identity.generate();
    const protocols = [_][]const u8{ PROTOCOL_ID, "/yamux/1.0.0" };

    var msg_buf: [1024]u8 = undefined;
    var msg_fbs = std.io.fixedBufferStream(&msg_buf);
    try encodeIdentify(msg_fbs.writer(), &id, &protocols);
    const written = msg_fbs.getWritten();

    // Walk fields by hand and check the types/numbers we expect.
    var seen_pubkey = false;
    var seen_proto_version = false;
    var seen_agent_version = false;
    var seen_protocols: usize = 0;

    var offset: usize = 0;
    while (offset < written.len) {
        const tag = try proto.readVarint(written[offset..]);
        offset += tag.bytes_read;
        const field_number = tag.value >> 3;
        const wire_type = tag.value & 0x07;
        const len = try proto.readVarint(written[offset..]);
        offset += len.bytes_read;
        const data_len: usize = @intCast(len.value);
        const data = written[offset .. offset + data_len];
        offset += data_len;

        try std.testing.expectEqual(@as(u64, 2), wire_type);
        switch (field_number) {
            1 => seen_pubkey = true,
            3 => seen_protocols += 1,
            5 => {
                seen_proto_version = true;
                try std.testing.expectEqualSlices(u8, PROTOCOL_VERSION, data);
            },
            6 => {
                seen_agent_version = true;
                try std.testing.expectEqualSlices(u8, AGENT_VERSION, data);
            },
            else => {},
        }
    }

    try std.testing.expect(seen_pubkey);
    try std.testing.expectEqual(@as(usize, 2), seen_protocols);
    try std.testing.expect(seen_proto_version);
    try std.testing.expect(seen_agent_version);
}

test "decodePeerInfo extracts pubkey, protocols, agent" {
    const id = try identity.Identity.generate();
    const protos = [_][]const u8{ "/ipfs/id/1.0.0", "/yamux/1.0.0", "/swarm/handshake/14.0.0/handshake" };

    var msg_buf: [1024]u8 = undefined;
    var msg_fbs = std.io.fixedBufferStream(&msg_buf);
    try encodeIdentify(msg_fbs.writer(), &id, &protos);
    const written = msg_fbs.getWritten();

    // decodePeerInfo takes ownership of the body buffer; copy.
    const body = try std.testing.allocator.dupe(u8, written);
    var info = try decodePeerInfo(std.testing.allocator, body);
    defer info.deinit();

    try std.testing.expect(info.public_key.len > 0);
    try std.testing.expectEqualSlices(u8, AGENT_VERSION, info.agent_version);
    try std.testing.expectEqualSlices(u8, PROTOCOL_VERSION, info.protocol_version);
    try std.testing.expectEqual(@as(usize, 3), info.protocols.len);
    try std.testing.expect(info.supports("/yamux/1.0.0"));
    try std.testing.expect(!info.supports("/quic-v1"));
}
