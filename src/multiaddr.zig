// libp2p multiaddr — wire-format parser/encoder.
//
// A multiaddr is a sequence of <code, value> pairs. Each `code` is a
// multicodec varint; the value's length depends on the code. Examples:
//
//   /ip4/127.0.0.1/tcp/1634
//     04 7f 00 00 01    — code 0x04 (ip4), 4 bytes IPv4
//     06 06 62          — code 0x06 (tcp), 2 bytes BE port (0x0662 = 1634)
//
//   /dnsaddr/sepolia.testnet.ethswarm.org
//     38 1d <29 ascii bytes>
//                       — code 0x38 (dnsaddr), varint length, then the host
//
//   /p2p/Qm…
//     a5 03 22 12 20 <32 sha256 bytes>
//                       — code 0x01a5 (p2p), varint length=34, multihash
//                         (sha2-256 = 0x12, len 0x20, 32 digest bytes)
//
// We do NOT implement /ws, /wss, /tls, /sni, /quic-v1, /webrtc, etc. yet —
// the things needed for plain TCP libp2p interop are above. Anything we
// don't recognise is rejected with InvalidMultiaddr (caller can fall back).

const std = @import("std");

pub const Code = enum(u32) {
    ip4 = 0x04,
    tcp = 0x06,
    udp = 0x0111,
    dns4 = 0x36,
    dns6 = 0x37,
    dnsaddr = 0x38,
    ip6 = 0x29,
    p2p = 0x01a5,
};

pub const Error = error{
    InvalidMultiaddr,
    UnsupportedComponent,
    BufferTooSmall,
    OutOfMemory,
};

const PROTO_HAS_NO_VALUE = struct {}; // (currently none of our codes are valueless)

fn isVarLengthValue(c: Code) bool {
    return switch (c) {
        .dns4, .dns6, .dnsaddr, .p2p => true,
        else => false,
    };
}

fn fixedValueLen(c: Code) ?usize {
    return switch (c) {
        .ip4 => 4,
        .ip6 => 16,
        .tcp, .udp => 2,
        else => null,
    };
}

pub const Multiaddr = struct {
    bytes: []const u8,
    allocator: std.mem.Allocator,
    owned: bool,

    pub fn fromBytesOwned(allocator: std.mem.Allocator, bytes: []const u8) !Multiaddr {
        const copy = try allocator.dupe(u8, bytes);
        return Multiaddr{ .bytes = copy, .allocator = allocator, .owned = true };
    }

    /// Borrows `bytes`; the multiaddr must not outlive the caller's buffer.
    pub fn fromBytesBorrow(allocator: std.mem.Allocator, bytes: []const u8) Multiaddr {
        return Multiaddr{ .bytes = bytes, .allocator = allocator, .owned = false };
    }

    pub fn deinit(self: Multiaddr) void {
        if (self.owned) self.allocator.free(self.bytes);
    }

    /// Iterate components in order. Returns null at end. Errors mid-iteration
    /// indicate a malformed multiaddr.
    pub fn iterator(self: Multiaddr) Iterator {
        return .{ .bytes = self.bytes, .pos = 0 };
    }

    pub const Iterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn next(self: *Iterator) !?Component {
            if (self.pos >= self.bytes.len) return null;
            const code_res = try readVarint(self.bytes[self.pos..]);
            self.pos += code_res.bytes_read;
            const code = std.meta.intToEnum(Code, code_res.value) catch return Error.UnsupportedComponent;

            if (fixedValueLen(code)) |n| {
                if (self.pos + n > self.bytes.len) return Error.InvalidMultiaddr;
                const value = self.bytes[self.pos .. self.pos + n];
                self.pos += n;
                return Component{ .code = code, .value = value };
            }
            if (isVarLengthValue(code)) {
                const len_res = try readVarint(self.bytes[self.pos..]);
                self.pos += len_res.bytes_read;
                const n: usize = @intCast(len_res.value);
                if (self.pos + n > self.bytes.len) return Error.InvalidMultiaddr;
                const value = self.bytes[self.pos .. self.pos + n];
                self.pos += n;
                return Component{ .code = code, .value = value };
            }
            return Error.UnsupportedComponent;
        }
    };

    pub const Component = struct {
        code: Code,
        value: []const u8,
    };

    /// Parses textual `/ip4/.../tcp/.../...`.
    pub fn fromText(allocator: std.mem.Allocator, text: []const u8) !Multiaddr {
        if (text.len == 0 or text[0] != '/') return Error.InvalidMultiaddr;

        var bytes_buf: std.ArrayList(u8) = .{};
        defer bytes_buf.deinit(allocator);

        var it = std.mem.tokenizeScalar(u8, text, '/');
        while (it.next()) |proto| {
            const code = parseProtoName(proto) orelse return Error.UnsupportedComponent;
            try writeVarint(&bytes_buf, allocator, @intFromEnum(code));

            if (fixedValueLen(code)) |_| {
                const val_str = it.next() orelse return Error.InvalidMultiaddr;
                switch (code) {
                    .ip4 => {
                        const ip = parseIp4(val_str) orelse return Error.InvalidMultiaddr;
                        try bytes_buf.appendSlice(allocator, &ip);
                    },
                    .tcp, .udp => {
                        const port = std.fmt.parseInt(u16, val_str, 10) catch return Error.InvalidMultiaddr;
                        var pbuf: [2]u8 = undefined;
                        std.mem.writeInt(u16, &pbuf, port, .big);
                        try bytes_buf.appendSlice(allocator, &pbuf);
                    },
                    .ip6 => {
                        // Defer real parsing — keep length stable but accept hex form.
                        return Error.UnsupportedComponent;
                    },
                    else => unreachable,
                }
            } else if (isVarLengthValue(code)) {
                const val_str = it.next() orelse return Error.InvalidMultiaddr;
                switch (code) {
                    .dns4, .dns6, .dnsaddr => {
                        try writeVarint(&bytes_buf, allocator, val_str.len);
                        try bytes_buf.appendSlice(allocator, val_str);
                    },
                    .p2p => {
                        // Decode base58btc into multihash bytes.
                        var mh_buf: [128]u8 = undefined;
                        const mh = try base58btcDecode(val_str, &mh_buf);
                        try writeVarint(&bytes_buf, allocator, mh.len);
                        try bytes_buf.appendSlice(allocator, mh);
                    },
                    else => unreachable,
                }
            } else {
                return Error.UnsupportedComponent;
            }
        }

        return Multiaddr{
            .bytes = try bytes_buf.toOwnedSlice(allocator),
            .allocator = allocator,
            .owned = true,
        };
    }

    /// Returns the IPv4 address + TCP port if the multiaddr starts with
    /// /ip4/X/tcp/Y. Trailing components (e.g. /p2p/...) are ignored.
    pub fn ip4Tcp(self: Multiaddr) ?struct { ip: [4]u8, port: u16 } {
        var it = self.iterator();
        const a = (it.next() catch return null) orelse return null;
        if (a.code != .ip4 or a.value.len != 4) return null;
        const b = (it.next() catch return null) orelse return null;
        if (b.code != .tcp or b.value.len != 2) return null;
        return .{
            .ip = .{ a.value[0], a.value[1], a.value[2], a.value[3] },
            .port = std.mem.readInt(u16, b.value[0..2], .big),
        };
    }

    pub const DnsHost = struct {
        kind: enum { dnsaddr, dns4, dns6 },
        host: []const u8,
    };

    pub fn dnsHost(self: Multiaddr) ?DnsHost {
        var it = self.iterator();
        while (it.next() catch null) |c| {
            switch (c.code) {
                .dnsaddr => return .{ .kind = .dnsaddr, .host = c.value },
                .dns4 => return .{ .kind = .dns4, .host = c.value },
                .dns6 => return .{ .kind = .dns6, .host = c.value },
                else => {},
            }
        }
        return null;
    }

    /// Returns the multihash bytes of the /p2p/<peer-id> component if present.
    pub fn peerIdBytes(self: Multiaddr) ?[]const u8 {
        var it = self.iterator();
        while (it.next() catch null) |c| {
            if (c.code == .p2p) return c.value;
        }
        return null;
    }
};

fn parseProtoName(name: []const u8) ?Code {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @field(Code, f.name);
    }
    return null;
}

fn parseIp4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return out;
}

const VARINT_MAX: usize = 10;

pub fn readVarint(buffer: []const u8) !struct { value: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buffer.len) : (i += 1) {
        if (i >= VARINT_MAX) return error.VarintTooLong;
        const b = buffer[i];
        result |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) return .{ .value = result, .bytes_read = i + 1 };
        if (shift == 63) return error.VarintTooLong;
        shift += 7;
    }
    return error.BufferTooShort;
}

fn writeVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var v = value;
    var tmp: [VARINT_MAX]u8 = undefined;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        tmp[i] = @intCast((v & 0x7F) | 0x80);
        v >>= 7;
    }
    tmp[i] = @intCast(v);
    try buf.appendSlice(allocator, tmp[0 .. i + 1]);
}

// ---- base58btc decode (Bitcoin alphabet) ----
const BASE58_ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58Index(c: u8) ?u32 {
    return for (BASE58_ALPHA, 0..) |ch, i| {
        if (ch == c) break @intCast(i);
    } else null;
}

/// Decodes base58btc into the caller-provided buffer; returns the decoded
/// slice. Used for parsing /p2p/<peer-id> peer-id strings into multihash bytes.
fn base58btcDecode(text: []const u8, out: []u8) ![]const u8 {
    // Count leading '1's = leading zero bytes.
    var leading_zeros: usize = 0;
    while (leading_zeros < text.len and text[leading_zeros] == '1') : (leading_zeros += 1) {}

    // Big-integer base conversion via byte-array accumulator (LSB at index 0).
    var buf: [128]u8 = [_]u8{0} ** 128;
    var hi: usize = 0;
    for (text) |c| {
        var carry: u32 = base58Index(c) orelse return error.InvalidBase58;
        var i: usize = 0;
        while (i < hi or carry > 0) : (i += 1) {
            if (i >= buf.len) return error.BufferTooSmall;
            carry += @as(u32, buf[i]) * 58;
            buf[i] = @intCast(carry & 0xff);
            carry >>= 8;
        }
        if (i > hi) hi = i;
    }

    const total = leading_zeros + hi;
    if (total > out.len) return error.BufferTooSmall;
    // Leading zero bytes in big-endian output.
    var pos: usize = 0;
    while (pos < leading_zeros) : (pos += 1) out[pos] = 0;
    // Copy buf[0..hi] reversed to out[leading_zeros..total].
    var j: usize = 0;
    while (j < hi) : (j += 1) out[leading_zeros + j] = buf[hi - 1 - j];
    return out[0..total];
}

// ---- tests ----

const testing = std.testing;

test "fromText /ip4/127.0.0.1/tcp/1634 round-trips and exposes ip+port" {
    var m = try Multiaddr.fromText(testing.allocator, "/ip4/127.0.0.1/tcp/1634");
    defer m.deinit();
    const ipt = m.ip4Tcp() orelse return error.NoIp4Tcp;
    try testing.expectEqualSlices(u8, &[_]u8{ 127, 0, 0, 1 }, &ipt.ip);
    try testing.expectEqual(@as(u16, 1634), ipt.port);
    // Wire bytes:  04 7f 00 00 01 06 06 62
    const want = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    try testing.expectEqualSlices(u8, &want, m.bytes);
}

test "fromText /dnsaddr/sepolia.testnet.ethswarm.org" {
    var m = try Multiaddr.fromText(testing.allocator, "/dnsaddr/sepolia.testnet.ethswarm.org");
    defer m.deinit();
    const dh = m.dnsHost() orelse return error.NoDns;
    try testing.expectEqual(@as(@TypeOf(dh.kind), .dnsaddr), dh.kind);
    try testing.expectEqualSlices(u8, "sepolia.testnet.ethswarm.org", dh.host);
}

test "fromText /ip4/.../tcp/.../p2p/Qm... extracts peer-id multihash" {
    // PeerID "QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N" decodes to
    //   12 20 <32 sha256 bytes>
    var m = try Multiaddr.fromText(
        testing.allocator,
        "/ip4/167.235.96.31/tcp/32491/p2p/QmediErcH3owEGGCNmQYXYqxpb2AWEwQqsiG2QSDjpWupH",
    );
    defer m.deinit();
    const ipt = m.ip4Tcp() orelse return error.NoIp4Tcp;
    try testing.expectEqual(@as(u16, 32491), ipt.port);
    const pid = m.peerIdBytes() orelse return error.NoPeerId;
    // First two bytes are multihash hash-fn-code + length.
    try testing.expectEqual(@as(u8, 0x12), pid[0]); // sha2-256
    try testing.expectEqual(@as(u8, 0x20), pid[1]); // 32-byte digest
    try testing.expectEqual(@as(usize, 34), pid.len);
}

test "iterator yields components in order" {
    var m = try Multiaddr.fromText(testing.allocator, "/ip4/10.0.0.1/tcp/4001");
    defer m.deinit();
    var it = m.iterator();

    const a = (try it.next()) orelse unreachable;
    try testing.expectEqual(Code.ip4, a.code);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, a.value);

    const b = (try it.next()) orelse unreachable;
    try testing.expectEqual(Code.tcp, b.code);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0F, 0xA1 }, b.value); // 4001 BE

    try testing.expect((try it.next()) == null);
}

test "fromText rejects malformed input" {
    try testing.expectError(Error.InvalidMultiaddr, Multiaddr.fromText(testing.allocator, "ip4/127.0.0.1"));
    try testing.expectError(Error.UnsupportedComponent, Multiaddr.fromText(testing.allocator, "/ws/foo"));
    try testing.expectError(Error.InvalidMultiaddr, Multiaddr.fromText(testing.allocator, "/ip4/127.0.0/tcp/1"));
}
