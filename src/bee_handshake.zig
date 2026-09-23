// Swarm Bee application-level handshake — `/swarm/handshake/{14,15}.0.0/handshake`.
//
// Wire flow when bee opens this stream against us (we're responder):
//   bee → us:  Syn { observed_underlay: bytes }
//   us  → bee: SynAck { syn: Syn(our view), ack: Ack(our bzz address) }
//   bee → us:  Ack { address: BzzAddress, network_id, full_node, welcome_message }
//
// Each message is varint-length-prefixed protobuf.
//
// Two versions, picked per peer from its Identify protocol list:
//   - 14.0.0 (bee < 2.8.0): BzzAddress = { underlay, signature, overlay };
//     the nonce travels in `Ack.Nonce` (field 4).
//   - 15.0.0 (bee >= 2.8.0): `Ack.Nonce` is gone; BzzAddress carries
//     { underlay, signature, overlay, nonce, timestamp, chequebook } and the
//     signature covers the three new fields. See bzz_address.zig for the
//     exact sign_data of each.
//
// Bee verifies our signature by recovering our public key, deriving the
// overlay from it, and checking it equals our advertised overlay. In 15.0.0
// bee also demands a verified chequebook — but only from peers whose Ack
// says `full_node`; zigbee is ultra-light, so it advertises none.

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");
const peer_id = @import("peer_id.zig");
const multiaddr = @import("multiaddr.zig");
const bzz_address = @import("bzz_address.zig");

pub const PROTOCOL_ID_V14 = "/swarm/handshake/14.0.0/handshake";
pub const PROTOCOL_ID_V15 = "/swarm/handshake/15.0.0/handshake";
pub const WELCOME_MESSAGE = "zigbee says hello";
pub const MAX_MSG_SIZE: usize = 128 * 1024;

pub const Version = enum {
    /// bee < 2.8.0.
    v14,
    /// bee >= 2.8.0.
    v15,

    pub fn protocolId(v: Version) []const u8 {
        return switch (v) {
            .v14 => PROTOCOL_ID_V14,
            .v15 => PROTOCOL_ID_V15,
        };
    }
};

pub const Error = error{
    InvalidSyn,
    InvalidAck,
    NetworkIdMismatch,
    HandshakeMessageTooLarge,
    OverlayMismatch,
    UnderlayDeserializeFailed,
};

/// Magic byte that prefixes the multi-underlay list format. Single-underlay
/// payloads are bare multiaddrs (so the first byte is necessarily a
/// multiaddr protocol code, never 0x99).
const UNDERLAY_LIST_PREFIX: u8 = 0x99;

/// Serializes a list of multiaddr binary blobs into bee's underlay format.
/// Single-entry → bare multiaddr (legacy/back-compat). Multi-entry or empty
/// → 0x99 prefix + sequence of (varint len, bytes).
fn serializeUnderlays(out: []u8, addrs: []const []const u8) ![]u8 {
    if (addrs.len == 1) {
        if (addrs[0].len > out.len) return error.BufferTooSmall;
        @memcpy(out[0..addrs[0].len], addrs[0]);
        return out[0..addrs[0].len];
    }
    var w = std.Io.Writer.fixed(out);
    try w.writeByte(UNDERLAY_LIST_PREFIX);
    for (addrs) |a| {
        try proto.writeVarint(&w, a.len);
        try w.writeAll(a);
    }
    return w.buffered();
}

/// Counts the multiaddrs encoded in an underlay payload without copying.
/// Used to verify the result is non-empty (bee rejects empty lists).
fn underlayCount(buf: []const u8) usize {
    if (buf.len == 0) return 0;
    if (buf[0] != UNDERLAY_LIST_PREFIX) return 1; // legacy single-multiaddr form
    var off: usize = 1;
    var n: usize = 0;
    while (off < buf.len) {
        const len_res = proto.readVarint(buf[off..]) catch return n;
        off += len_res.bytes_read;
        const ulen: usize = @intCast(len_res.value);
        if (off + ulen > buf.len) return n;
        off += ulen;
        n += 1;
    }
    return n;
}

/// Configuration passed in by the caller — everything zigbee can't infer
/// from the connection itself.
pub const Config = struct {
    version: Version,
    network_id: u64,
    full_node: bool,
    /// 32-byte nonce that, together with our identity's Ethereum address and
    /// the network id, derives our overlay address.
    nonce: [32]u8,
    /// Our advertised underlays as multiaddr binary blobs (each one a
    /// /ip4/.../tcp/.../p2p/<peer-id> or similar). Bee accepts any list ≥1
    /// as long as the signature checks out and the overlay matches.
    underlays: []const []const u8,
    /// Unix seconds stamped into (and signed with) our BzzAddress. v15 only;
    /// bee rejects 0, values > its clock + 60 s, and values older than the
    /// last one it stored for us.
    timestamp: i64 = 0,
    welcome_message: []const u8 = WELCOME_MESSAGE,
};

pub const PeerInfo = struct {
    overlay: [32]u8,
    network_id: u64,
    full_node: bool,
    welcome_message: []const u8,
    /// Nonce + ethereum address recovered from the peer's signed BzzAddress.
    eth_address: [20]u8,
    /// Buffer the slices borrow from. Free via deinit.
    _allocator: std.mem.Allocator,
    _buffer: []u8,

    pub fn deinit(self: PeerInfo) void {
        self._allocator.free(self._buffer);
    }
};

/// Our signed BzzAddress, ready to encode. `underlay` borrows from the
/// buffer passed to `signOurAddress`.
const OurAddress = struct {
    underlay: []const u8,
    overlay: [32]u8,
    signature: [65]u8,
    nonce: [32]u8,
    timestamp: i64,
};

fn signOurAddress(underlay_buf: []u8, id: *const identity.Identity, cfg: Config) !OurAddress {
    var overlay: [32]u8 = undefined;
    id.overlayAddress(cfg.network_id, cfg.nonce, &overlay);
    const underlay = try serializeUnderlays(underlay_buf, cfg.underlays);

    // No chequebook: the V15 default (20 zero bytes) is what bee signs for
    // an absent one.
    const v15: ?bzz_address.V15 = switch (cfg.version) {
        .v14 => null,
        .v15 => .{ .timestamp = cfg.timestamp },
    };
    var sd_buf: [8192]u8 = undefined;
    const sd = try bzz_address.buildSignData(&sd_buf, underlay, overlay, cfg.network_id, cfg.nonce, v15);
    var sig: [65]u8 = undefined;
    try identity.signEthereum(id.private_key, sd, &sig);

    return .{
        .underlay = underlay,
        .overlay = overlay,
        .signature = sig,
        .nonce = cfg.nonce,
        .timestamp = cfg.timestamp,
    };
}

/// Structural checks + signature verification of the peer's Ack. Returns
/// the peer's overlay and recovered Ethereum address.
fn verifyPeerAck(version: Version, ack: ParsedAck) !struct { overlay: [32]u8, eth_address: [20]u8 } {
    const a = ack.address;
    if (a.overlay.len != 32) return Error.InvalidAck;
    if (underlayCount(a.underlay) == 0) return Error.InvalidAck;
    if (a.signature.len != 65) return Error.InvalidAck;

    const nonce_bytes = switch (version) {
        .v14 => ack.nonce,
        .v15 => a.nonce,
    };
    if (nonce_bytes.len != 32) return Error.InvalidAck;

    const v15: ?bzz_address.V15 = switch (version) {
        .v14 => null,
        .v15 => blk: {
            if (a.timestamp <= 0) return Error.InvalidAck;
            break :blk .{
                .timestamp = a.timestamp,
                .chequebook = bzz_address.chequebookFromWire(a.chequebook) catch return Error.InvalidAck,
            };
        },
    };

    const overlay = a.overlay[0..32].*;
    const verified = bzz_address.verify(
        a.underlay,
        overlay,
        a.signature[0..65].*,
        nonce_bytes[0..32].*,
        ack.network_id,
        v15,
    ) catch return Error.InvalidAck;
    return .{ .overlay = overlay, .eth_address = verified.eth_address };
}

/// Initiator side: we open the stream, send Syn → read SynAck → send Ack.
/// Caller must have already done multistream-select for
/// `cfg.version.protocolId()`.
///   - `peer_observed_underlay`: a multiaddr binary containing /p2p/<peer-id>
///     of the responder. Bee uses this to figure out its own observed
///     address; the spec also requires it to embed bee's PeerID.
pub fn initiate(
    allocator: std.mem.Allocator,
    stream: *yamux.Stream,
    id: *const identity.Identity,
    cfg: Config,
    peer_observed_underlay: []const u8,
) !PeerInfo {
    // 1. Send Syn { observed_underlay: peer's multiaddr }
    var syn_payload_buf: [4096]u8 = undefined;
    const syn_payload = try encodeSyn(&syn_payload_buf, peer_observed_underlay);
    try writeDelimited(stream, syn_payload);

    // 2. Read SynAck { syn, ack } and verify the peer's BzzAddress.
    const synack_buf = try readDelimited(allocator, stream);
    defer allocator.free(synack_buf);
    const parsed = try parseSynAck(synack_buf);
    if (parsed.ack.network_id != cfg.network_id) return Error.NetworkIdMismatch;
    const peer = try verifyPeerAck(cfg.version, parsed.ack);

    // 3. Build and send our Ack.
    var our_underlay_buf: [4096]u8 = undefined;
    const ours = try signOurAddress(&our_underlay_buf, id, cfg);

    var ack_payload_buf: [8192]u8 = undefined;
    const ack_payload = try encodeAck(
        &ack_payload_buf,
        cfg.version,
        ours,
        cfg.network_id,
        cfg.full_node,
        cfg.welcome_message,
    );
    try writeDelimited(stream, ack_payload);

    // Copy peer fields into a heap buffer the caller owns.
    const owned = try allocator.alloc(u8, parsed.ack.welcome_message.len);
    @memcpy(owned, parsed.ack.welcome_message);

    return PeerInfo{
        .overlay = peer.overlay,
        .network_id = parsed.ack.network_id,
        .full_node = parsed.ack.full_node,
        .welcome_message = owned,
        .eth_address = peer.eth_address,
        ._allocator = allocator,
        ._buffer = owned,
    };
}

/// Responder side: bee opened the stream, we serve the handshake.
pub fn respond(
    allocator: std.mem.Allocator,
    stream: *yamux.Stream,
    id: *const identity.Identity,
    cfg: Config,
) !PeerInfo {
    // 1. We've already done multistream-select with bee at this point —
    //    p2p.zig wrote our hello + the protocol echo. Move into protobuf.

    // 2. Read Syn (bee's view of our underlays — we mostly ignore it).
    const syn_buf = try readDelimited(allocator, stream);
    defer allocator.free(syn_buf);
    _ = try parseSyn(syn_buf);

    // 3. Build and send SynAck.
    var underlays_buf: [4096]u8 = undefined;
    const ours = try signOurAddress(&underlays_buf, id, cfg);

    var synack_payload_buf: [8192]u8 = undefined;
    const synack_payload = try encodeSynAck(
        &synack_payload_buf,
        // syn.observed_underlay: send empty for now; bee's responder doesn't
        // verify this against its own peer ID.
        &[_]u8{},
        cfg.version,
        ours,
        cfg.network_id,
        cfg.full_node,
        cfg.welcome_message,
    );

    try writeDelimited(stream, synack_payload);

    // 4. Read peer's Ack and verify.
    const ack_buf = try readDelimited(allocator, stream);
    errdefer allocator.free(ack_buf);
    const parsed = try parseAck(ack_buf);
    if (parsed.network_id != cfg.network_id) return Error.NetworkIdMismatch;
    const peer = try verifyPeerAck(cfg.version, parsed);

    return PeerInfo{
        .overlay = peer.overlay,
        .network_id = parsed.network_id,
        .full_node = parsed.full_node,
        .welcome_message = parsed.welcome_message,
        .eth_address = peer.eth_address,
        ._allocator = allocator,
        ._buffer = ack_buf,
    };
}

// ---------- protobuf encode/decode ----------

const ParsedSyn = struct {
    observed_underlay: []const u8,
};

const ParsedAck = struct {
    address: bzz_address.Parsed = .{},
    network_id: u64 = 0,
    full_node: bool = false,
    /// Legacy (14.0.0) field 4; empty under 15.0.0, where the nonce lives
    /// in `address.nonce`.
    nonce: []const u8 = &[_]u8{},
    welcome_message: []const u8 = &[_]u8{},
};

const ParsedSynAck = struct {
    syn: ParsedSyn,
    ack: ParsedAck,
};

fn parseSynAck(buf: []const u8) !ParsedSynAck {
    var out = ParsedSynAck{
        .syn = .{ .observed_underlay = &[_]u8{} },
        .ack = .{},
    };
    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) return Error.InvalidAck;
        const len_res = try proto.readVarint(buf[off..]);
        off += len_res.bytes_read;
        const ulen: usize = @intCast(len_res.value);
        if (off + ulen > buf.len) return Error.InvalidAck;
        const data = buf[off .. off + ulen];
        off += ulen;
        switch (fnum) {
            1 => out.syn = try parseSyn(data),
            2 => out.ack = try parseAck(data),
            else => {},
        }
    }
    return out;
}

fn parseSyn(buf: []const u8) !ParsedSyn {
    var observed: []const u8 = &[_]u8{};
    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) return Error.InvalidSyn;
        const len_res = try proto.readVarint(buf[off..]);
        off += len_res.bytes_read;
        const ulen: usize = @intCast(len_res.value);
        if (off + ulen > buf.len) return Error.InvalidSyn;
        if (fnum == 1) observed = buf[off .. off + ulen];
        off += ulen;
    }
    return .{ .observed_underlay = observed };
}

fn parseAck(buf: []const u8) !ParsedAck {
    var ack = ParsedAck{};
    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        switch (wt) {
            0 => {
                const v = try proto.readVarint(buf[off..]);
                off += v.bytes_read;
                switch (fnum) {
                    2 => ack.network_id = v.value,
                    3 => ack.full_node = v.value != 0,
                    else => {},
                }
            },
            2 => {
                const len_res = try proto.readVarint(buf[off..]);
                off += len_res.bytes_read;
                const ulen: usize = @intCast(len_res.value);
                if (off + ulen > buf.len) return Error.InvalidAck;
                const data = buf[off .. off + ulen];
                off += ulen;
                switch (fnum) {
                    1 => ack.address = bzz_address.decode(data) catch return Error.InvalidAck,
                    4 => ack.nonce = data,
                    99 => ack.welcome_message = data,
                    else => {},
                }
            },
            else => return Error.InvalidAck,
        }
    }
    return ack;
}

/// Encodes a SynAck whose payload contains both `Syn` (field 1) and `Ack`
/// (field 2) sub-messages. Returns the slice into `out`.
fn encodeSynAck(
    out: []u8,
    syn_observed_underlay: []const u8,
    version: Version,
    addr: OurAddress,
    network_id: u64,
    full_node: bool,
    welcome_message: []const u8,
) ![]u8 {
    var w = std.Io.Writer.fixed(out);

    // Field 1: syn (embedded message).
    var syn_buf: [4096]u8 = undefined;
    const syn_bytes = try encodeSyn(&syn_buf, syn_observed_underlay);
    try proto.writeVarint(&w, (1 << 3) | 2);
    try proto.writeVarint(&w, syn_bytes.len);
    try w.writeAll(syn_bytes);

    // Field 2: ack (embedded message).
    var ack_buf: [8192]u8 = undefined;
    const ack_bytes = try encodeAck(&ack_buf, version, addr, network_id, full_node, welcome_message);
    try proto.writeVarint(&w, (2 << 3) | 2);
    try proto.writeVarint(&w, ack_bytes.len);
    try w.writeAll(ack_bytes);

    return w.buffered();
}

fn encodeSyn(out: []u8, observed_underlay: []const u8) ![]u8 {
    var w = std.Io.Writer.fixed(out);
    if (observed_underlay.len > 0) {
        try proto.writeVarint(&w, (1 << 3) | 2);
        try proto.writeVarint(&w, observed_underlay.len);
        try w.writeAll(observed_underlay);
    }
    return w.buffered();
}

fn encodeBzzAddress(out: []u8, version: Version, addr: OurAddress) ![]u8 {
    var w = std.Io.Writer.fixed(out);
    // Field 1: Underlay (bytes)
    try proto.writeVarint(&w, (1 << 3) | 2);
    try proto.writeVarint(&w, addr.underlay.len);
    try w.writeAll(addr.underlay);
    // Field 2: Signature (bytes)
    try proto.writeVarint(&w, (2 << 3) | 2);
    try proto.writeVarint(&w, addr.signature.len);
    try w.writeAll(&addr.signature);
    // Field 3: Overlay (bytes)
    try proto.writeVarint(&w, (3 << 3) | 2);
    try proto.writeVarint(&w, addr.overlay.len);
    try w.writeAll(&addr.overlay);
    if (version == .v15) {
        // Field 4: Nonce (bytes)
        try proto.writeVarint(&w, (4 << 3) | 2);
        try proto.writeVarint(&w, addr.nonce.len);
        try w.writeAll(&addr.nonce);
        // Field 5: Timestamp (int64)
        try proto.writeVarint(&w, (5 << 3) | 0);
        try proto.writeVarint(&w, @bitCast(addr.timestamp));
        // Field 6: ChequebookAddress — bee sends the 20 zero bytes of
        // `common.Address{}.Bytes()` when it has none; match it.
        try proto.writeVarint(&w, (6 << 3) | 2);
        try proto.writeVarint(&w, bzz_address.CHEQUEBOOK_LEN);
        try w.splatByteAll(0, bzz_address.CHEQUEBOOK_LEN);
    }
    return w.buffered();
}

fn encodeAck(
    out: []u8,
    version: Version,
    addr: OurAddress,
    network_id: u64,
    full_node: bool,
    welcome_message: []const u8,
) ![]u8 {
    var w = std.Io.Writer.fixed(out);
    // Field 1: Address (BzzAddress, embedded message)
    var addr_buf: [4096]u8 = undefined;
    const addr_bytes = try encodeBzzAddress(&addr_buf, version, addr);
    try proto.writeVarint(&w, (1 << 3) | 2);
    try proto.writeVarint(&w, addr_bytes.len);
    try w.writeAll(addr_bytes);
    // Field 2: NetworkID (varint)
    try proto.writeVarint(&w, (2 << 3) | 0);
    try proto.writeVarint(&w, network_id);
    // Field 3: FullNode (bool)
    try proto.writeVarint(&w, (3 << 3) | 0);
    try proto.writeVarint(&w, if (full_node) 1 else 0);
    if (version == .v14) {
        // Field 4: Nonce (bytes) — moved into BzzAddress in 15.0.0.
        try proto.writeVarint(&w, (4 << 3) | 2);
        try proto.writeVarint(&w, addr.nonce.len);
        try w.writeAll(&addr.nonce);
    }
    // Field 99: WelcomeMessage (string)
    if (welcome_message.len > 0) {
        try proto.writeVarint(&w, (99 << 3) | 2);
        try proto.writeVarint(&w, welcome_message.len);
        try w.writeAll(welcome_message);
    }
    return w.buffered();
}

// ---------- delimited framing ----------

fn writeDelimited(stream: *yamux.Stream, payload: []const u8) !void {
    var len_buf: [10]u8 = undefined;
    var w = std.Io.Writer.fixed(&len_buf);
    try proto.writeVarint(&w, payload.len);
    try stream.writeAll(w.buffered());
    try stream.writeAll(payload);
}

fn readDelimited(allocator: std.mem.Allocator, stream: *yamux.Stream) ![]u8 {
    // Read varint length one byte at a time.
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

    if (len > MAX_MSG_SIZE) return Error.HandshakeMessageTooLarge;
    const ulen: usize = @intCast(len);
    const buf = try allocator.alloc(u8, ulen);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < ulen) {
        const n = try stream.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
    return buf;
}

// ---------- tests ----------

// (buildSignData and BzzAddress signature-recovery tests now live in
// bzz_address.zig, which owns those primitives.)

test "encode + parse Ack round-trips (v14 and v15)" {
    const underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    const addr = OurAddress{
        .underlay = &underlay,
        .overlay = [_]u8{0xAA} ** 32,
        .signature = [_]u8{0xBB} ** 65,
        .nonce = [_]u8{0xCC} ** 32,
        .timestamp = 1_790_000_000,
    };
    const wm = "hello";

    for ([_]Version{ .v14, .v15 }) |version| {
        var buf: [4096]u8 = undefined;
        const ack_bytes = try encodeAck(&buf, version, addr, 10, true, wm);

        const parsed = try parseAck(ack_bytes);
        try std.testing.expectEqual(@as(u64, 10), parsed.network_id);
        try std.testing.expect(parsed.full_node);
        try std.testing.expectEqualSlices(u8, &underlay, parsed.address.underlay);
        try std.testing.expectEqualSlices(u8, &addr.overlay, parsed.address.overlay);
        try std.testing.expectEqualSlices(u8, &addr.signature, parsed.address.signature);
        try std.testing.expectEqualSlices(u8, wm, parsed.welcome_message);
        switch (version) {
            .v14 => {
                try std.testing.expectEqualSlices(u8, &addr.nonce, parsed.nonce);
                try std.testing.expectEqual(@as(usize, 0), parsed.address.nonce.len);
            },
            .v15 => {
                try std.testing.expectEqual(@as(usize, 0), parsed.nonce.len);
                try std.testing.expectEqualSlices(u8, &addr.nonce, parsed.address.nonce);
                try std.testing.expectEqual(addr.timestamp, parsed.address.timestamp);
                try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 20), parsed.address.chequebook);
            },
        }
    }
}

test "v15 handshake: our signed Ack verifies on the peer side" {
    const id = try identity.Identity.generate();
    const our_underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    const underlays = [_][]const u8{&our_underlay};
    const cfg = Config{
        .version = .v15,
        .network_id = 10,
        .full_node = false,
        .nonce = [_]u8{0x42} ** 32,
        .underlays = &underlays,
        .timestamp = 1_790_000_000,
    };

    var ub: [4096]u8 = undefined;
    const ours = try signOurAddress(&ub, &id, cfg);
    var buf: [8192]u8 = undefined;
    const parsed = try parseAck(try encodeAck(&buf, .v15, ours, cfg.network_id, false, ""));
    const peer = try verifyPeerAck(.v15, parsed);
    try std.testing.expectEqualSlices(u8, &ours.overlay, &peer.overlay);

    // The same bytes checked under the v14 rules must fail: no Ack.Nonce.
    try std.testing.expectError(Error.InvalidAck, verifyPeerAck(.v14, parsed));
}

test "underlayCount handles empty, legacy single, and prefixed list" {
    const empty = [_]u8{};
    try std.testing.expectEqual(@as(usize, 0), underlayCount(&empty));

    const single_legacy = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    try std.testing.expectEqual(@as(usize, 1), underlayCount(&single_legacy));

    // List form: 0x99 || varint(8) || 8 bytes || varint(4) || 4 bytes
    const list = [_]u8{ 0x99, 8, 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62, 4, 0xaa, 0xbb, 0xcc, 0xdd };
    try std.testing.expectEqual(@as(usize, 2), underlayCount(&list));
}
