// libp2p PeerID derivation.
//
// PeerID = multihash(<hash-fn-code>, <digest-len>, <digest>)
//   - For marshaled-pubkey-len ≤ 42 bytes: identity hash (code 0x00, digest =
//     the marshaled pubkey itself).
//   - For longer keys (RSA, ECDSA-P256, etc.): SHA-256 (code 0x12, len 0x20,
//     32 sha256 bytes).
//
// "Marshaled pubkey" is the protobuf libp2p `PublicKey` message:
//   field 1 (varint, key_type): 2=Secp256k1, 3=ECDSA, ...
//   field 2 (length-delim, data): the wire form of the key
//
// For our Secp256k1 identity that's:
//   tag 0x08 || 0x02
//   tag 0x12 || 0x21 || 33-byte SEC-1 compressed point
// = 37 bytes, well under 42, so we use identity multihash.

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");

const MAX_INLINE_KEY_LEN: usize = 42;

/// Marshals our libp2p `PublicKey` protobuf for a Secp256k1 identity.
/// Returns the slice into `out` that holds the bytes.
pub fn marshalSecp256k1PublicKey(id: *const identity.Identity, out: []u8) ![]u8 {
    var compressed: [identity.COMPRESSED_PUBKEY_SIZE]u8 = undefined;
    try id.compressedPublicKey(&compressed);

    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 0); // field 1, varint
    try proto.writeVarint(w, 2); // KeyType.Secp256k1
    try proto.writeVarint(w, (2 << 3) | 2); // field 2, length-delim
    try proto.writeVarint(w, compressed.len);
    try w.writeAll(&compressed);
    return fbs.getWritten();
}

/// Computes the libp2p PeerID multihash for an `Identity`. Writes into `out`
/// (max 64 bytes — actually 39 for our case) and returns the written slice.
pub fn computePeerId(id: *const identity.Identity, out: []u8) ![]u8 {
    var marshal_buf: [64]u8 = undefined;
    const marshaled = try marshalSecp256k1PublicKey(id, &marshal_buf);

    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    if (marshaled.len <= MAX_INLINE_KEY_LEN) {
        // Identity multihash: code 0x00 || varint(len) || raw bytes.
        try proto.writeVarint(w, 0x00);
        try proto.writeVarint(w, marshaled.len);
        try w.writeAll(marshaled);
    } else {
        // SHA-256 multihash: code 0x12 || 0x20 || 32 sha256 bytes.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(marshaled, &digest, .{});
        try proto.writeVarint(w, 0x12);
        try proto.writeVarint(w, 32);
        try w.writeAll(&digest);
    }
    return fbs.getWritten();
}

/// Marshals an arbitrary libp2p PublicKey proto: { Type: key_type, Data: data }.
fn marshalLibp2pPublicKey(out: []u8, key_type: u64, data: []const u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 0);
    try proto.writeVarint(w, key_type);
    try proto.writeVarint(w, (2 << 3) | 2);
    try proto.writeVarint(w, data.len);
    try w.writeAll(data);
    return fbs.getWritten();
}

/// Computes a PeerID multihash for an arbitrary peer's libp2p public key.
/// Identity multihash for marshaled-proto length ≤ 42, sha2-256 multihash
/// otherwise.
pub fn peerIdFromLibp2pKey(out: []u8, key_type: u64, data: []const u8) ![]u8 {
    var marshal_buf: [256]u8 = undefined;
    const marshaled = try marshalLibp2pPublicKey(&marshal_buf, key_type, data);

    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    if (marshaled.len <= MAX_INLINE_KEY_LEN) {
        try proto.writeVarint(w, 0x00);
        try proto.writeVarint(w, marshaled.len);
        try w.writeAll(marshaled);
    } else {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(marshaled, &digest, .{});
        try proto.writeVarint(w, 0x12);
        try proto.writeVarint(w, 32);
        try w.writeAll(&digest);
    }
    return fbs.getWritten();
}

/// Builds `/ip4/<ip>/tcp/<port>/p2p/<peer-id>` for a peer whose PeerID
/// multihash is already computed (e.g. via peerIdFromLibp2pKey).
pub fn buildIp4TcpP2pMultiaddrFromPeerId(out: []u8, ip: [4]u8, port: u16, peer_id_mh: []const u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    try proto.writeVarint(w, 0x04);
    try w.writeAll(&ip);
    try proto.writeVarint(w, 0x06);
    var port_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_buf, port, .big);
    try w.writeAll(&port_buf);
    try proto.writeVarint(w, 0x01a5);
    try proto.writeVarint(w, peer_id_mh.len);
    try w.writeAll(peer_id_mh);
    return fbs.getWritten();
}

/// Builds the wire bytes for `/ip4/<ip>/tcp/<port>/p2p/<our-peer-id>`. This
/// is the underlay form bee accepts in a BzzAddress: a single multiaddr (no
/// 0x99 prefix) containing the /p2p/ component so bee can recover our peer
/// identity.
pub fn buildIp4TcpP2pMultiaddr(out: []u8, id: *const identity.Identity, ip: [4]u8, port: u16) ![]u8 {
    var pid_buf: [64]u8 = undefined;
    const pid = try computePeerId(id, &pid_buf);

    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();

    // /ip4/<A.B.C.D>: code 0x04 (varint = 1 byte) + 4 bytes.
    try proto.writeVarint(w, 0x04);
    try w.writeAll(&ip);

    // /tcp/<N>: code 0x06 + 2-byte BE port.
    try proto.writeVarint(w, 0x06);
    var port_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_buf, port, .big);
    try w.writeAll(&port_buf);

    // /p2p/<multihash>: code 0x01a5 (varint A5 03) + varint(len(mh)) + mh.
    try proto.writeVarint(w, 0x01a5);
    try proto.writeVarint(w, pid.len);
    try w.writeAll(pid);

    return fbs.getWritten();
}

test "buildIp4TcpP2pMultiaddr produces a valid multiaddr binary" {
    const id = try identity.Identity.generate();
    var buf: [128]u8 = undefined;
    const ma_bytes = try buildIp4TcpP2pMultiaddr(&buf, &id, .{ 127, 0, 0, 1 }, 1635);
    try std.testing.expectEqual(@as(u8, 0x04), ma_bytes[0]); // ip4 code
    try std.testing.expectEqual(@as(u8, 127), ma_bytes[1]);
    // /tcp at offset 5: byte 5 = 0x06, bytes 6..8 = 0x06 0x63 (port 1635 BE)
    try std.testing.expectEqual(@as(u8, 0x06), ma_bytes[5]);
    try std.testing.expectEqual(@as(u8, 0x06), ma_bytes[6]);
    try std.testing.expectEqual(@as(u8, 0x63), ma_bytes[7]);
    // /p2p at offset 8: 0xA5 0x03 (varint 0x01a5)
    try std.testing.expectEqual(@as(u8, 0xA5), ma_bytes[8]);
    try std.testing.expectEqual(@as(u8, 0x03), ma_bytes[9]);

    // Walk via the multiaddr parser and confirm the components match.
    const multiaddr = @import("multiaddr.zig");
    var ma = multiaddr.Multiaddr.fromBytesBorrow(std.testing.allocator, ma_bytes);
    const ipt = ma.ip4Tcp() orelse return error.NoIp4Tcp;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 0, 0, 1 }, &ipt.ip);
    try std.testing.expectEqual(@as(u16, 1635), ipt.port);
    const pid_back = ma.peerIdBytes() orelse return error.NoPeerId;
    try std.testing.expect(pid_back.len > 0);
}

test "computePeerId produces an identity-multihash for a Secp256k1 key" {
    const id = try identity.Identity.generate();
    var pid_buf: [64]u8 = undefined;
    const pid = try computePeerId(&id, &pid_buf);
    // Identity hash code (varint 0x00 = 1 byte) + length varint (1 byte for ≤127)
    // + raw marshaled-pubkey (37 bytes for our config) = 39 bytes total.
    try std.testing.expectEqual(@as(usize, 39), pid.len);
    try std.testing.expectEqual(@as(u8, 0x00), pid[0]); // identity multihash code
    try std.testing.expectEqual(@as(u8, 37), pid[1]); // length of marshaled pubkey
}
