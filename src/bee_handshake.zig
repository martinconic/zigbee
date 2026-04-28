// Swarm Bee application-level handshake — `/swarm/handshake/14.0.0/handshake`.
//
// Wire flow when bee opens this stream against us (we're responder):
//   bee → us:  Syn { observed_underlay: bytes }
//   us  → bee: SynAck { syn: Syn(our view), ack: Ack(our bzz address) }
//   bee → us:  Ack { address: BzzAddress, network_id, full_node, nonce, welcome_message }
//
// Each message is varint-length-prefixed protobuf.
//
// BzzAddress = { underlay: bytes, signature: bytes, overlay: bytes }
//   - underlay: serialized list of multiaddrs (single-multiaddr legacy form,
//     or 0x99-prefixed varint-length list).
//   - overlay: 32-byte swarm address (= keccak256(eth_addr ‖ networkID_LE_u64
//     ‖ nonce_32)).
//   - signature: 65-byte r||s||v Ethereum-style signature over
//        sign_data = "bee-handshake-" || underlay || overlay || networkID_BE_u64
//     hashed with EIP-191 + Keccak-256, signed with secp256k1.
//
// Bee verifies our signature by recovering our public key, deriving the
// overlay from it, and checking it equals our advertised overlay.

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");
const peer_id = @import("peer_id.zig");
const multiaddr = @import("multiaddr.zig");
const bzz_address = @import("bzz_address.zig");

pub const PROTOCOL_ID = "/swarm/handshake/14.0.0/handshake";
pub const WELCOME_MESSAGE = "zigbee says hello";
pub const MAX_MSG_SIZE: usize = 128 * 1024;

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
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    try w.writeByte(UNDERLAY_LIST_PREFIX);
    for (addrs) |a| {
        try proto.writeVarint(w, a.len);
        try w.writeAll(a);
    }
    return fbs.getWritten();
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
    network_id: u64,
    full_node: bool,
    /// 32-byte nonce that, together with our identity's Ethereum address and
    /// the network id, derives our overlay address.
    nonce: [32]u8,
    /// Our advertised underlays as multiaddr binary blobs (each one a
    /// /ip4/.../tcp/.../p2p/<peer-id> or similar). Bee accepts any list ≥1
    /// as long as the signature checks out and (if validateOverlay is on)
    /// the overlay matches.
    underlays: []const []const u8,
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

/// Initiator side: we open the stream, send Syn → read SynAck → send Ack.
/// Caller must have already done multistream-select for PROTOCOL_ID.
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

    // 2. Read SynAck { syn, ack }
    const synack_buf = try readDelimited(allocator, stream);
    defer allocator.free(synack_buf);
    const parsed = try parseSynAck(synack_buf);
    if (parsed.ack.network_id != cfg.network_id) return Error.NetworkIdMismatch;
    if (parsed.ack.address.overlay.len != 32) return Error.InvalidAck;
    if (underlayCount(parsed.ack.address.underlay) == 0) return Error.InvalidAck;
    if (parsed.ack.address.signature.len != 65) return Error.InvalidAck;
    if (parsed.ack.nonce.len != 32) return Error.InvalidAck;

    // Verify peer's BzzAddress (delegates signature recovery + overlay
    // derivation to the shared bzz_address module).
    const peer_overlay32 = parsed.ack.address.overlay[0..32].*;
    var peer_sig: [65]u8 = undefined;
    @memcpy(&peer_sig, parsed.ack.address.signature[0..65]);
    var peer_nonce32: [32]u8 = undefined;
    @memcpy(&peer_nonce32, parsed.ack.nonce[0..32]);
    const verified = bzz_address.verify(
        parsed.ack.address.underlay,
        peer_overlay32,
        peer_sig,
        peer_nonce32,
        parsed.ack.network_id,
    ) catch return Error.InvalidAck;
    const peer_eth = verified.eth_address;

    // 3. Build and send our Ack.
    var our_overlay: [32]u8 = undefined;
    id.overlayAddress(cfg.network_id, cfg.nonce, &our_overlay);

    var our_underlay_buf: [4096]u8 = undefined;
    const our_underlay = try serializeUnderlays(&our_underlay_buf, cfg.underlays);

    var our_sd_buf: [8192]u8 = undefined;
    const our_sd = try bzz_address.buildSignData(&our_sd_buf, our_underlay, our_overlay, cfg.network_id);
    var our_sig: [65]u8 = undefined;
    try identity.signEthereum(id.private_key, our_sd, &our_sig);

    var ack_payload_buf: [8192]u8 = undefined;
    const ack_payload = try encodeAck(
        &ack_payload_buf,
        our_underlay,
        our_overlay,
        our_sig,
        cfg.network_id,
        cfg.full_node,
        cfg.nonce,
        cfg.welcome_message,
    );
    try writeDelimited(stream, ack_payload);

    // Copy peer fields into a heap buffer the caller owns.
    const owned = try allocator.alloc(u8, parsed.ack.welcome_message.len);
    @memcpy(owned, parsed.ack.welcome_message);

    return PeerInfo{
        .overlay = peer_overlay32,
        .network_id = parsed.ack.network_id,
        .full_node = parsed.ack.full_node,
        .welcome_message = owned,
        .eth_address = peer_eth,
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
    const overlay = cfg_overlay: {
        var ov: [32]u8 = undefined;
        id.overlayAddress(cfg.network_id, cfg.nonce, &ov);
        break :cfg_overlay ov;
    };

    var underlays_buf: [4096]u8 = undefined;
    const our_underlay = try serializeUnderlays(&underlays_buf, cfg.underlays);

    var sign_data_buf: [8192]u8 = undefined;
    const sign_data = try bzz_address.buildSignData(&sign_data_buf, our_underlay, overlay, cfg.network_id);

    var sig: [65]u8 = undefined;
    try identity.signEthereum(id.private_key, sign_data, &sig);

    var synack_payload_buf: [8192]u8 = undefined;
    const synack_payload = try encodeSynAck(
        &synack_payload_buf,
        // syn.observed_underlay: send empty for now; bee's responder doesn't
        // verify this against its own peer ID.
        &[_]u8{},
        // ack:
        our_underlay,
        overlay,
        sig,
        cfg.network_id,
        cfg.full_node,
        cfg.nonce,
        cfg.welcome_message,
    );

    try writeDelimited(stream, synack_payload);

    // 4. Read peer's Ack and verify.
    const ack_buf = try readDelimited(allocator, stream);
    errdefer allocator.free(ack_buf);
    var parsed = try parseAck(ack_buf);

    if (parsed.network_id != cfg.network_id) {
        allocator.free(ack_buf);
        return Error.NetworkIdMismatch;
    }
    if (parsed.address.overlay.len != 32) {
        allocator.free(ack_buf);
        return Error.InvalidAck;
    }
    if (underlayCount(parsed.address.underlay) == 0) {
        allocator.free(ack_buf);
        return Error.InvalidAck;
    }

    // Recover the peer's pubkey and check it derives the advertised overlay.
    if (parsed.address.signature.len != 65 or parsed.nonce.len != 32) {
        allocator.free(ack_buf);
        return Error.InvalidAck;
    }
    const peer_overlay32 = parsed.address.overlay[0..32].*;
    var peer_sig: [65]u8 = undefined;
    @memcpy(&peer_sig, parsed.address.signature[0..65]);
    var nonce32: [32]u8 = undefined;
    @memcpy(&nonce32, parsed.nonce[0..32]);
    const verified = bzz_address.verify(
        parsed.address.underlay,
        peer_overlay32,
        peer_sig,
        nonce32,
        parsed.network_id,
    ) catch {
        allocator.free(ack_buf);
        return Error.InvalidAck;
    };
    const peer_eth = verified.eth_address;

    return PeerInfo{
        .overlay = peer_overlay32,
        .network_id = parsed.network_id,
        .full_node = parsed.full_node,
        .welcome_message = parsed.welcome_message,
        .eth_address = peer_eth,
        ._allocator = allocator,
        ._buffer = ack_buf,
    };
}

// ---------- protobuf encode/decode ----------

const ParsedSyn = struct {
    observed_underlay: []const u8,
};

const ParsedBzzAddress = struct {
    underlay: []const u8,
    signature: []const u8,
    overlay: []const u8,
};

const ParsedAck = struct {
    address: ParsedBzzAddress,
    network_id: u64 = 0,
    full_node: bool = false,
    nonce: []const u8,
    welcome_message: []const u8,
};

const ParsedSynAck = struct {
    syn: ParsedSyn,
    ack: ParsedAck,
};

fn parseSynAck(buf: []const u8) !ParsedSynAck {
    var out = ParsedSynAck{
        .syn = .{ .observed_underlay = &[_]u8{} },
        .ack = .{
            .address = .{ .underlay = &[_]u8{}, .signature = &[_]u8{}, .overlay = &[_]u8{} },
            .nonce = &[_]u8{},
            .welcome_message = &[_]u8{},
        },
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

fn parseBzzAddress(buf: []const u8) !ParsedBzzAddress {
    var addr = ParsedBzzAddress{ .underlay = &[_]u8{}, .signature = &[_]u8{}, .overlay = &[_]u8{} };
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
        switch (fnum) {
            1 => addr.underlay = buf[off .. off + ulen],
            2 => addr.signature = buf[off .. off + ulen],
            3 => addr.overlay = buf[off .. off + ulen],
            else => {},
        }
        off += ulen;
    }
    return addr;
}

fn parseAck(buf: []const u8) !ParsedAck {
    var ack = ParsedAck{
        .address = .{ .underlay = &[_]u8{}, .signature = &[_]u8{}, .overlay = &[_]u8{} },
        .nonce = &[_]u8{},
        .welcome_message = &[_]u8{},
    };
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
                    1 => ack.address = try parseBzzAddress(data),
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
    underlay: []const u8,
    overlay: [32]u8,
    signature: [65]u8,
    network_id: u64,
    full_node: bool,
    nonce: [32]u8,
    welcome_message: []const u8,
) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();

    // Field 1: syn (embedded message).
    var syn_buf: [4096]u8 = undefined;
    const syn_bytes = try encodeSyn(&syn_buf, syn_observed_underlay);
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, syn_bytes.len);
    try w.writeAll(syn_bytes);

    // Field 2: ack (embedded message).
    var ack_buf: [8192]u8 = undefined;
    const ack_bytes = try encodeAck(
        &ack_buf,
        underlay,
        overlay,
        signature,
        network_id,
        full_node,
        nonce,
        welcome_message,
    );
    try proto.writeVarint(w, (2 << 3) | 2);
    try proto.writeVarint(w, ack_bytes.len);
    try w.writeAll(ack_bytes);

    return fbs.getWritten();
}

fn encodeSyn(out: []u8, observed_underlay: []const u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    if (observed_underlay.len > 0) {
        try proto.writeVarint(w, (1 << 3) | 2);
        try proto.writeVarint(w, observed_underlay.len);
        try w.writeAll(observed_underlay);
    }
    return fbs.getWritten();
}

fn encodeBzzAddress(out: []u8, underlay: []const u8, overlay: [32]u8, signature: [65]u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    // Field 1: Underlay (bytes)
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, underlay.len);
    try w.writeAll(underlay);
    // Field 2: Signature (bytes)
    try proto.writeVarint(w, (2 << 3) | 2);
    try proto.writeVarint(w, signature.len);
    try w.writeAll(&signature);
    // Field 3: Overlay (bytes)
    try proto.writeVarint(w, (3 << 3) | 2);
    try proto.writeVarint(w, overlay.len);
    try w.writeAll(&overlay);
    return fbs.getWritten();
}

fn encodeAck(
    out: []u8,
    underlay: []const u8,
    overlay: [32]u8,
    signature: [65]u8,
    network_id: u64,
    full_node: bool,
    nonce: [32]u8,
    welcome_message: []const u8,
) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    // Field 1: Address (BzzAddress, embedded message)
    var addr_buf: [4096]u8 = undefined;
    const addr_bytes = try encodeBzzAddress(&addr_buf, underlay, overlay, signature);
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, addr_bytes.len);
    try w.writeAll(addr_bytes);
    // Field 2: NetworkID (varint)
    try proto.writeVarint(w, (2 << 3) | 0);
    try proto.writeVarint(w, network_id);
    // Field 3: FullNode (bool)
    try proto.writeVarint(w, (3 << 3) | 0);
    try proto.writeVarint(w, if (full_node) 1 else 0);
    // Field 4: Nonce (bytes)
    try proto.writeVarint(w, (4 << 3) | 2);
    try proto.writeVarint(w, nonce.len);
    try w.writeAll(&nonce);
    // Field 99: WelcomeMessage (string)
    if (welcome_message.len > 0) {
        try proto.writeVarint(w, (99 << 3) | 2);
        try proto.writeVarint(w, welcome_message.len);
        try w.writeAll(welcome_message);
    }
    return fbs.getWritten();
}

// ---------- delimited framing ----------

fn writeDelimited(stream: *yamux.Stream, payload: []const u8) !void {
    var len_buf: [10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&len_buf);
    try proto.writeVarint(fbs.writer(), payload.len);
    try stream.writeAll(fbs.getWritten());
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

test "encode + parse Ack round-trips" {
    const network_id: u64 = 10;
    const overlay: [32]u8 = [_]u8{0xAA} ** 32;
    const sig: [65]u8 = [_]u8{0xBB} ** 65;
    const nonce: [32]u8 = [_]u8{0xCC} ** 32;
    const underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    const wm = "hello";

    var buf: [4096]u8 = undefined;
    const ack_bytes = try encodeAck(&buf, &underlay, overlay, sig, network_id, true, nonce, wm);

    const parsed = try parseAck(ack_bytes);
    try std.testing.expectEqual(network_id, parsed.network_id);
    try std.testing.expect(parsed.full_node);
    try std.testing.expectEqualSlices(u8, &underlay, parsed.address.underlay);
    try std.testing.expectEqualSlices(u8, &overlay, parsed.address.overlay);
    try std.testing.expectEqualSlices(u8, &sig, parsed.address.signature);
    try std.testing.expectEqualSlices(u8, &nonce, parsed.nonce);
    try std.testing.expectEqualSlices(u8, wm, parsed.welcome_message);
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
