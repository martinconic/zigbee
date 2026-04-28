// Bzz address: the on-the-wire representation of a Swarm peer.
//
// Used in two places:
//   - The bzz handshake (`/swarm/handshake/14.0.0/handshake`), embedded
//     inside `Ack.Address` — has fields underlay, signature, overlay.
//     The nonce travels alongside it in `Ack.Nonce`.
//   - Hive (`/swarm/hive/1.1.0/peers`), where each entry is a complete
//     `BzzAddress` proto: underlay, signature, overlay, AND nonce.
//
// Both share the same signing scheme:
//   sign_data = "bee-handshake-" || underlay || overlay || networkID_BE_u64
//   sig       = sign(EIP-191(sign_data)) using secp256k1, 65-byte r||s||v
// And the recovered public key must satisfy
//   overlay  = keccak256(eth_addr ‖ networkID_LE_u64 ‖ nonce_32)
// where eth_addr = keccak256(uncompressed_pubkey[1..65])[12..32].
//
// proto:
//   message BzzAddress {
//       bytes Underlay  = 1;
//       bytes Signature = 2;
//       bytes Overlay   = 3;
//       bytes Nonce     = 4;   // present in hive's BzzAddress, absent in
//                              // the handshake's (carried in Ack.Nonce).
//   }

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");

pub const SIGN_PREFIX: []const u8 = "bee-handshake-";
pub const OVERLAY_LEN: usize = 32;
pub const NONCE_LEN: usize = 32;
pub const SIGNATURE_LEN: usize = 65;
pub const ETH_ADDR_LEN: usize = 20;

pub const Error = error{
    InvalidProtobuf,
    InvalidBzzAddress,
    OverlayMismatch,
    SignatureRecoveryFailed,
    BufferTooSmall,
};

/// Parsed (but not yet verified) BzzAddress fields, all borrowing from the
/// caller's input buffer. Use `parse` for an owned, signature-verified
/// version with a derived Ethereum address attached.
pub const Parsed = struct {
    underlay: []const u8 = &[_]u8{},
    signature: []const u8 = &[_]u8{},
    overlay: []const u8 = &[_]u8{},
    nonce: []const u8 = &[_]u8{}, // empty if the proto didn't include field 4
};

/// Verified, owning copy of a peer's BzzAddress. All slices point into
/// `_buffer`, which the allocator owns; free via `deinit`.
pub const Verified = struct {
    overlay: [OVERLAY_LEN]u8,
    nonce: [NONCE_LEN]u8,
    eth_address: [ETH_ADDR_LEN]u8,
    /// Concatenated underlay bytes (single-multiaddr legacy form or 0x99
    /// list-prefix variant — see bee_handshake.serializeUnderlays for the
    /// outbound side; here we just keep the raw blob).
    underlay: []const u8,
    signature: [SIGNATURE_LEN]u8,
    network_id: u64,

    _allocator: std.mem.Allocator,
    _buffer: []u8,

    pub fn deinit(self: Verified) void {
        self._allocator.free(self._buffer);
    }
};

/// Decodes a BzzAddress protobuf into a Parsed view (no allocation, no
/// signature verification — slices borrow from `buf`).
pub fn decode(buf: []const u8) !Parsed {
    var out = Parsed{};
    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) return Error.InvalidProtobuf;
        const lr = try proto.readVarint(buf[off..]);
        off += lr.bytes_read;
        const ulen: usize = @intCast(lr.value);
        if (off + ulen > buf.len) return Error.InvalidProtobuf;
        switch (fnum) {
            1 => out.underlay = buf[off .. off + ulen],
            2 => out.signature = buf[off .. off + ulen],
            3 => out.overlay = buf[off .. off + ulen],
            4 => out.nonce = buf[off .. off + ulen],
            else => {},
        }
        off += ulen;
    }
    return out;
}

/// Builds the bytes that the BzzAddress signature covers, before EIP-191
/// prefixing. Returns the slice into `out`.
pub fn buildSignData(out: []u8, underlay: []const u8, overlay: [OVERLAY_LEN]u8, network_id: u64) ![]u8 {
    const total = SIGN_PREFIX.len + underlay.len + OVERLAY_LEN + 8;
    if (total > out.len) return Error.BufferTooSmall;
    @memcpy(out[0..SIGN_PREFIX.len], SIGN_PREFIX);
    @memcpy(out[SIGN_PREFIX.len..][0..underlay.len], underlay);
    @memcpy(out[SIGN_PREFIX.len + underlay.len ..][0..OVERLAY_LEN], &overlay);
    std.mem.writeInt(
        u64,
        out[SIGN_PREFIX.len + underlay.len + OVERLAY_LEN ..][0..8],
        network_id,
        .big,
    );
    return out[0..total];
}

/// Computes the 20-byte Ethereum address from a 33-byte SEC-1 compressed
/// secp256k1 pubkey.
pub fn ethAddressFromCompressed(compressed: [33]u8, out: *[ETH_ADDR_LEN]u8) !void {
    const ctx = identity.secp.secp256k1_context_create(identity.secp.SECP256K1_CONTEXT_NONE) orelse return error.SecpContextCreationFailed;
    defer identity.secp.secp256k1_context_destroy(ctx);

    var parsed: identity.secp.secp256k1_pubkey = undefined;
    if (identity.secp.secp256k1_ec_pubkey_parse(ctx, &parsed, &compressed, 33) != 1) {
        return error.InvalidPublicKey;
    }
    var uncompressed: [65]u8 = undefined;
    var out_len: usize = 65;
    if (identity.secp.secp256k1_ec_pubkey_serialize(ctx, &uncompressed, &out_len, &parsed, identity.secp.SECP256K1_EC_UNCOMPRESSED) != 1) {
        return error.PubkeySerializationFailed;
    }
    var h: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(uncompressed[1..65], &h, .{});
    @memcpy(out, h[12..32]);
}

/// Verifies a BzzAddress signature and returns the recovered Ethereum
/// address. `nonce` may be the address's own field-4 nonce (hive form) or
/// a separately-provided one (handshake form, where Ack.Nonce holds it).
pub fn verify(
    underlay: []const u8,
    overlay: [OVERLAY_LEN]u8,
    signature: [SIGNATURE_LEN]u8,
    nonce: [NONCE_LEN]u8,
    network_id: u64,
) !struct { eth_address: [ETH_ADDR_LEN]u8, pubkey_compressed: [33]u8 } {
    var sd_buf: [8192]u8 = undefined;
    const sd = try buildSignData(&sd_buf, underlay, overlay, network_id);

    var pubkey: [33]u8 = undefined;
    identity.recoverEthereum(sd, signature, &pubkey) catch return Error.SignatureRecoveryFailed;

    var eth: [ETH_ADDR_LEN]u8 = undefined;
    try ethAddressFromCompressed(pubkey, &eth);

    var derived_overlay: [OVERLAY_LEN]u8 = undefined;
    identity.overlayFromEthereumAddress(eth, network_id, nonce, &derived_overlay);
    if (!std.mem.eql(u8, &derived_overlay, &overlay)) return Error.OverlayMismatch;

    return .{ .eth_address = eth, .pubkey_compressed = pubkey };
}

/// Decode-only parse: structural well-formedness, no signature recovery.
/// Used by hive, where bee's broadcast strips/filters underlays after
/// signing — so the signature can't be re-verified end-to-end on the wire.
/// Bee accepts these as advisory peer hints and verifies when it later
/// runs a direct handshake; we do the same.
pub fn parseNoVerify(allocator: std.mem.Allocator, buf: []const u8) !Verified {
    const p = try decode(buf);
    if (p.overlay.len != OVERLAY_LEN) return Error.InvalidBzzAddress;
    if (p.signature.len != SIGNATURE_LEN) return Error.InvalidBzzAddress;
    if (p.nonce.len != NONCE_LEN) return Error.InvalidBzzAddress;
    if (p.underlay.len == 0) return Error.InvalidBzzAddress;

    var overlay: [OVERLAY_LEN]u8 = undefined;
    @memcpy(&overlay, p.overlay);
    var nonce: [NONCE_LEN]u8 = undefined;
    @memcpy(&nonce, p.nonce);
    var sig: [SIGNATURE_LEN]u8 = undefined;
    @memcpy(&sig, p.signature);

    const buffer = try allocator.alloc(u8, p.underlay.len);
    @memcpy(buffer, p.underlay);

    return Verified{
        .overlay = overlay,
        .nonce = nonce,
        .eth_address = [_]u8{0} ** ETH_ADDR_LEN, // unknown until we handshake directly
        .underlay = buffer,
        .signature = sig,
        .network_id = 0, // unknown — caller usually knows the network
        ._allocator = allocator,
        ._buffer = buffer,
    };
}

/// Decodes + verifies + copies. Caller owns the returned `Verified`; call
/// `deinit` to free. `external_nonce` is used only when the proto's own
/// field-4 nonce is empty (handshake form). For hive form, pass any value
/// and the proto's own nonce wins.
pub fn parse(
    allocator: std.mem.Allocator,
    buf: []const u8,
    network_id: u64,
    external_nonce: ?[NONCE_LEN]u8,
) !Verified {
    const p = try decode(buf);
    if (p.overlay.len != OVERLAY_LEN) return Error.InvalidBzzAddress;
    if (p.signature.len != SIGNATURE_LEN) return Error.InvalidBzzAddress;
    if (p.underlay.len == 0) return Error.InvalidBzzAddress;

    var nonce: [NONCE_LEN]u8 = undefined;
    if (p.nonce.len == NONCE_LEN) {
        @memcpy(&nonce, p.nonce);
    } else if (p.nonce.len == 0 and external_nonce != null) {
        nonce = external_nonce.?;
    } else {
        return Error.InvalidBzzAddress;
    }

    var overlay: [OVERLAY_LEN]u8 = undefined;
    @memcpy(&overlay, p.overlay);
    var sig: [SIGNATURE_LEN]u8 = undefined;
    @memcpy(&sig, p.signature);

    const verified = try verify(p.underlay, overlay, sig, nonce, network_id);

    // Copy the (possibly multi-)underlay blob into our own buffer.
    const buffer = try allocator.alloc(u8, p.underlay.len);
    @memcpy(buffer, p.underlay);

    return Verified{
        .overlay = overlay,
        .nonce = nonce,
        .eth_address = verified.eth_address,
        .underlay = buffer,
        .signature = sig,
        .network_id = network_id,
        ._allocator = allocator,
        ._buffer = buffer,
    };
}

// ---------- tests ----------

const testing = std.testing;

/// Iterates the entries of a bee-style underlay payload. Two formats:
///   - bare multiaddr (single underlay, legacy form),
///   - 0x99 prefix || (varint len, multiaddr bytes)+ (multi-underlay).
pub const UnderlayIterator = struct {
    bytes: []const u8,
    pos: usize,
    /// Set when bytes is the legacy single-multiaddr form. We yield the
    /// whole buffer once and then stop.
    legacy_done: bool = false,

    pub fn init(bytes: []const u8) UnderlayIterator {
        return .{ .bytes = bytes, .pos = if (bytes.len > 0 and bytes[0] == 0x99) 1 else 0 };
    }

    pub fn next(self: *UnderlayIterator) !?[]const u8 {
        if (self.bytes.len == 0) return null;
        if (self.bytes[0] != 0x99) {
            if (self.legacy_done) return null;
            self.legacy_done = true;
            return self.bytes;
        }
        if (self.pos >= self.bytes.len) return null;
        const lr = try proto.readVarint(self.bytes[self.pos..]);
        self.pos += lr.bytes_read;
        const ulen: usize = @intCast(lr.value);
        if (self.pos + ulen > self.bytes.len) return error.InvalidUnderlay;
        const out = self.bytes[self.pos .. self.pos + ulen];
        self.pos += ulen;
        return out;
    }
};

test "UnderlayIterator: legacy single underlay" {
    const single = [_]u8{ 0x04, 127, 0, 0, 1, 0x06, 0x06, 0x62 };
    var it = UnderlayIterator.init(&single);
    const first = (try it.next()) orelse return error.NoEntry;
    try std.testing.expectEqualSlices(u8, &single, first);
    try std.testing.expect((try it.next()) == null);
}

test "UnderlayIterator: 0x99-prefixed list of two entries" {
    // /ip4/10.0.0.1/tcp/1634 (8 bytes) + /ip4/192.168.1.2/tcp/1635 (8 bytes)
    const list = [_]u8{
        0x99,
        8,    0x04, 10,  0,    0,    1,    0x06, 0x06, 0x62,
        8,    0x04, 192, 168,  1,    2,    0x06, 0x06, 0x63,
    };
    var it = UnderlayIterator.init(&list);
    const a = (try it.next()) orelse return error.NoEntry;
    try std.testing.expectEqual(@as(usize, 8), a.len);
    try std.testing.expectEqual(@as(u8, 10), a[1]);
    const b = (try it.next()) orelse return error.NoEntry;
    try std.testing.expectEqual(@as(usize, 8), b.len);
    try std.testing.expectEqual(@as(u8, 192), b[1]);
    try std.testing.expect((try it.next()) == null);
}

test "buildSignData layout matches bee's generateSignData" {
    const overlay: [OVERLAY_LEN]u8 = [_]u8{0xAA} ** OVERLAY_LEN;
    const underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    var buf: [256]u8 = undefined;
    const sd = try buildSignData(&buf, &underlay, overlay, 10);
    try testing.expectEqualSlices(u8, "bee-handshake-", sd[0..14]);
    try testing.expectEqualSlices(u8, &underlay, sd[14 .. 14 + underlay.len]);
    try testing.expectEqualSlices(u8, &overlay, sd[14 + underlay.len .. 14 + underlay.len + 32]);
    var net_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &net_be, 10, .big);
    try testing.expectEqualSlices(u8, &net_be, sd[14 + underlay.len + 32 ..]);
}

test "self-signed BzzAddress round-trips through parse" {
    const id = try identity.Identity.generate();
    const network_id: u64 = 10;
    const nonce: [NONCE_LEN]u8 = [_]u8{0x77} ** NONCE_LEN;

    var overlay: [OVERLAY_LEN]u8 = undefined;
    id.overlayAddress(network_id, nonce, &overlay);

    const underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    var sd_buf: [256]u8 = undefined;
    const sd = try buildSignData(&sd_buf, &underlay, overlay, network_id);
    var sig: [SIGNATURE_LEN]u8 = undefined;
    try identity.signEthereum(id.private_key, sd, &sig);

    // Encode hive-form BzzAddress (with nonce in the proto).
    var enc_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&enc_buf);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, underlay.len);
    try w.writeAll(&underlay);
    try proto.writeVarint(w, (2 << 3) | 2);
    try proto.writeVarint(w, sig.len);
    try w.writeAll(&sig);
    try proto.writeVarint(w, (3 << 3) | 2);
    try proto.writeVarint(w, overlay.len);
    try w.writeAll(&overlay);
    try proto.writeVarint(w, (4 << 3) | 2);
    try proto.writeVarint(w, nonce.len);
    try w.writeAll(&nonce);

    const v = try parse(testing.allocator, fbs.getWritten(), network_id, null);
    defer v.deinit();
    try testing.expectEqualSlices(u8, &overlay, &v.overlay);
    try testing.expectEqualSlices(u8, &nonce, &v.nonce);
    try testing.expectEqualSlices(u8, &underlay, v.underlay);

    // Sanity: the recovered eth_address is OUR identity's eth_address.
    var our_eth: [ETH_ADDR_LEN]u8 = undefined;
    id.ethereumAddress(&our_eth);
    try testing.expectEqualSlices(u8, &our_eth, &v.eth_address);
}

test "parse rejects an overlay that doesn't match the recovered key" {
    const id = try identity.Identity.generate();
    const network_id: u64 = 10;
    const nonce: [NONCE_LEN]u8 = [_]u8{0x77} ** NONCE_LEN;

    // Sign over the WRONG overlay so verification fails.
    var bad_overlay: [OVERLAY_LEN]u8 = [_]u8{0xFF} ** OVERLAY_LEN;
    const underlay = [_]u8{ 0x04, 0x7f, 0x00, 0x00, 0x01, 0x06, 0x06, 0x62 };
    var sd_buf: [256]u8 = undefined;
    const sd = try buildSignData(&sd_buf, &underlay, bad_overlay, network_id);
    var sig: [SIGNATURE_LEN]u8 = undefined;
    try identity.signEthereum(id.private_key, sd, &sig);

    var enc_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&enc_buf);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, underlay.len);
    try w.writeAll(&underlay);
    try proto.writeVarint(w, (2 << 3) | 2);
    try proto.writeVarint(w, sig.len);
    try w.writeAll(&sig);
    try proto.writeVarint(w, (3 << 3) | 2);
    try proto.writeVarint(w, bad_overlay.len);
    try w.writeAll(&bad_overlay);
    try proto.writeVarint(w, (4 << 3) | 2);
    try proto.writeVarint(w, nonce.len);
    try w.writeAll(&nonce);

    try testing.expectError(Error.OverlayMismatch, parse(testing.allocator, fbs.getWritten(), network_id, null));
}
