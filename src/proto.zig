const std = @import("std");

pub const NoiseHandshakePayload = struct {
    identity_key: []const u8 = &[_]u8{},
    identity_sig: []const u8 = &[_]u8{},
    /// Field 3 — historical/unused by libp2p; kept for compat with our older tests.
    data: []const u8 = &[_]u8{},
    /// Field 4 — embedded NoiseExtensions (preferred path for muxer negotiation).
    /// Holds the raw protobuf bytes of the embedded message; nil ⇒ field omitted.
    extensions_bytes: []const u8 = &[_]u8{},
};

/// libp2p NoiseExtensions (in NoiseHandshakePayload field 4):
///   message NoiseExtensions {
///       repeated bytes  webtransport_certhashes = 1;
///       repeated string stream_muxers           = 2;
///   }
pub const NoiseExtensions = struct {
    /// Each entry is a libp2p protocol ID (e.g. "/yamux/1.0.0").
    stream_muxers: []const []const u8 = &[_][]const u8{},
};

pub fn encodeNoiseExtensions(writer: anytype, ext: NoiseExtensions) !void {
    for (ext.stream_muxers) |m| {
        try writeVarint(writer, (2 << 3) | 2);
        try writeVarint(writer, m.len);
        try writer.writeAll(m);
    }
}

/// Returns a list of stream-muxer protocol IDs that the buffer advertises.
/// `out_buf` must be large enough to hold pointers to up to `max_muxers`
/// muxer slices. The slices borrow from `buffer`.
pub fn decodeNoiseExtensionsMuxers(buffer: []const u8, out_buf: [][]const u8) !usize {
    var offset: usize = 0;
    var n: usize = 0;
    while (offset < buffer.len) {
        const tag_res = try readVarint(buffer[offset..]);
        offset += tag_res.bytes_read;
        const tag = tag_res.value;
        const wire_type = tag & 0x07;
        const field_number = tag >> 3;

        const len_res = try readVarint(buffer[offset..]);
        offset += len_res.bytes_read;
        const len: usize = @intCast(len_res.value);
        if (offset + len > buffer.len) return error.BufferTooShort;

        if (wire_type == 2 and field_number == 2) {
            if (n >= out_buf.len) return error.TooManyMuxers;
            out_buf[n] = buffer[offset .. offset + len];
            n += 1;
        }
        offset += len;
    }
    return n;
}

/// Reads a varint from a slice of bytes and returns the value and bytes read.
/// A protobuf varint is at most 10 bytes for a u64.
pub fn readVarint(buffer: []const u8) !struct { value: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var bytes_read: usize = 0;

    while (bytes_read < buffer.len) : (bytes_read += 1) {
        if (bytes_read >= 10) return error.VarintTooLong;
        const b = buffer[bytes_read];
        result |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
            return .{ .value = result, .bytes_read = bytes_read + 1 };
        }
        if (shift == 63) return error.VarintTooLong;
        shift += 7;
    }
    return error.BufferTooShort;
}

pub fn decodeNoiseHandshakePayload(buffer: []const u8) !NoiseHandshakePayload {
    var payload = NoiseHandshakePayload{
        .identity_key = &[_]u8{},
        .identity_sig = &[_]u8{},
        .data = &[_]u8{},
    };

    var offset: usize = 0;
    while (offset < buffer.len) {
        const tag_res = try readVarint(buffer[offset..]);
        offset += tag_res.bytes_read;
        const tag = tag_res.value;
        
        const wire_type = tag & 0x07;
        const field_number = tag >> 3;

        // All fields in NoiseHandshakePayload are Length-Delimited (wire type 2)
        if (wire_type != 2) return error.InvalidProtobuf;

        const len_res = try readVarint(buffer[offset..]);
        offset += len_res.bytes_read;
        const len = @as(usize, @intCast(len_res.value));

        if (offset + len > buffer.len) return error.BufferTooShort;

        const data = buffer[offset .. offset + len];
        offset += len;

        switch (field_number) {
            1 => payload.identity_key = data,
            2 => payload.identity_sig = data,
            3 => payload.data = data,
            4 => payload.extensions_bytes = data,
            else => {}, // Ignore unknown fields
        }
    }

    return payload;
}

pub const Libp2pPubKey = struct {
    key_type: u64,
    data: []const u8,
};

pub fn decodeLibp2pPublicKey(buffer: []const u8) !Libp2pPubKey {
    var pubkey = Libp2pPubKey{
        .key_type = 0,
        .data = &[_]u8{},
    };

    var offset: usize = 0;
    while (offset < buffer.len) {
        const tag_res = try readVarint(buffer[offset..]);
        offset += tag_res.bytes_read;
        const tag = tag_res.value;
        
        const wire_type = tag & 0x07;
        const field_number = tag >> 3;

        if (wire_type == 0 and field_number == 1) {
            const type_res = try readVarint(buffer[offset..]);
            offset += type_res.bytes_read;
            pubkey.key_type = type_res.value;
        } else if (wire_type == 2 and field_number == 2) {
            const len_res = try readVarint(buffer[offset..]);
            offset += len_res.bytes_read;
            const len = @as(usize, @intCast(len_res.value));
            
            if (offset + len > buffer.len) return error.BufferTooShort;
            pubkey.data = buffer[offset .. offset + len];
            offset += len;
        } else {
            // skip unknown fields
            if (wire_type == 0) {
                const skip_res = try readVarint(buffer[offset..]);
                offset += skip_res.bytes_read;
            } else if (wire_type == 2) {
                const len_res = try readVarint(buffer[offset..]);
                offset += len_res.bytes_read;
                const len = @as(usize, @intCast(len_res.value));
                offset += len;
            } else {
                return error.UnsupportedWireType;
            }
        }
    }

    return pubkey;
}

/// Encodes a varint to a writer
pub fn writeVarint(writer: anytype, value: u64) !void {
    var val = value;
    var buf: [10]u8 = undefined;
    var i: usize = 0;

    while (val >= 0x80) {
        buf[i] = @as(u8, @intCast((val & 0x7F) | 0x80));
        val >>= 7;
        i += 1;
    }
    buf[i] = @as(u8, @intCast(val));
    try writer.writeAll(buf[0 .. i + 1]);
}

pub fn encodeNoiseHandshakePayload(writer: anytype, payload: NoiseHandshakePayload) !void {
    // identity_key: field 1
    if (payload.identity_key.len > 0) {
        try writeVarint(writer, (1 << 3) | 2);
        try writeVarint(writer, payload.identity_key.len);
        try writer.writeAll(payload.identity_key);
    }
    // identity_sig: field 2
    if (payload.identity_sig.len > 0) {
        try writeVarint(writer, (2 << 3) | 2);
        try writeVarint(writer, payload.identity_sig.len);
        try writer.writeAll(payload.identity_sig);
    }
    // data: field 3
    if (payload.data.len > 0) {
        try writeVarint(writer, (3 << 3) | 2);
        try writeVarint(writer, payload.data.len);
        try writer.writeAll(payload.data);
    }
    // extensions: field 4 (embedded NoiseExtensions)
    if (payload.extensions_bytes.len > 0) {
        try writeVarint(writer, (4 << 3) | 2);
        try writeVarint(writer, payload.extensions_bytes.len);
        try writer.writeAll(payload.extensions_bytes);
    }
}

test "decode payload" {
    // 0x0a 0x04 0x11 0x22 0x33 0x44 -> field 1, len 4, data
    const buf = [_]u8{ 0x0a, 0x04, 0x11, 0x22, 0x33, 0x44, 0x12, 0x02, 0xaa, 0xbb };
    const payload = try decodeNoiseHandshakePayload(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, payload.identity_key);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, payload.identity_sig);
}

test "varint roundtrip across the previously-overflowing boundary" {
    // The old code used shift: u5 and panicked on the 6th continuation byte.
    // Pick values that need 1, 5, 6, 9 and 10 wire bytes.
    const values = [_]u64{ 0, 127, 128, 0x1FFFFFFF, 0xFFFFFFFFFF, std.math.maxInt(u64) };
    for (values) |v| {
        var buf: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try writeVarint(fbs.writer(), v);
        const written = fbs.getWritten();
        const got = try readVarint(written);
        try std.testing.expectEqual(v, got.value);
        try std.testing.expectEqual(written.len, got.bytes_read);
    }
}

test "varint rejects a malformed 11-byte stream" {
    // Eleven bytes all with the continuation bit set is malformed.
    const bad = [_]u8{0xFF} ** 11;
    try std.testing.expectError(error.VarintTooLong, readVarint(&bad));
}

test "encode payload" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    
    const payload = NoiseHandshakePayload{
        .identity_key = &[_]u8{ 0x11, 0x22, 0x33, 0x44 },
        .identity_sig = &[_]u8{ 0xaa, 0xbb },
        .data = &[_]u8{},
    };
    
    try encodeNoiseHandshakePayload(fbs.writer(), payload);
    const expected = [_]u8{ 0x0a, 0x04, 0x11, 0x22, 0x33, 0x44, 0x12, 0x02, 0xaa, 0xbb };
    try std.testing.expectEqualSlices(u8, &expected, fbs.getWritten());
}

pub const IdentifyMessage = struct {
    protocol_version: []const u8,
    agent_version: []const u8,
    public_key: []const u8,
    listen_addrs: [][]const u8,
    observed_addr: []const u8,
    protocols: [][]const u8,
};

/// Encodes the libp2p Identify payload
pub fn encodeIdentifyPayload(writer: anytype, payload: IdentifyMessage) !void {
    // 1: publicKey (bytes)
    if (payload.public_key.len > 0) {
        try writeVarint(writer, (1 << 3) | 2);
        try writeVarint(writer, payload.public_key.len);
        try writer.writeAll(payload.public_key);
    }
    
    // 2: listenAddrs (repeated bytes)
    for (payload.listen_addrs) |addr| {
        try writeVarint(writer, (2 << 3) | 2);
        try writeVarint(writer, addr.len);
        try writer.writeAll(addr);
    }
    
    // 3: protocols (repeated string)
    for (payload.protocols) |proto_name| {
        try writeVarint(writer, (3 << 3) | 2);
        try writeVarint(writer, proto_name.len);
        try writer.writeAll(proto_name);
    }
    
    // 4: observedAddr (bytes)
    if (payload.observed_addr.len > 0) {
        try writeVarint(writer, (4 << 3) | 2);
        try writeVarint(writer, payload.observed_addr.len);
        try writer.writeAll(payload.observed_addr);
    }
    
    // 5: protocolVersion (string)
    if (payload.protocol_version.len > 0) {
        try writeVarint(writer, (5 << 3) | 2);
        try writeVarint(writer, payload.protocol_version.len);
        try writer.writeAll(payload.protocol_version);
    }
    
    // 6: agentVersion (string)
    if (payload.agent_version.len > 0) {
        try writeVarint(writer, (6 << 3) | 2);
        try writeVarint(writer, payload.agent_version.len);
        try writer.writeAll(payload.agent_version);
    }
}
