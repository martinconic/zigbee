// libp2p public-key envelope handling.
//
// libp2p PublicKey protobuf:
//   message PublicKey { required KeyType type = 1; required bytes data = 2; }
//   enum KeyType { RSA = 0; Ed25519 = 1; Secp256k1 = 2; ECDSA = 3; }
//
// On-the-wire encodings of the `data` field per type:
//   Secp256k1: 33-byte SEC-1 compressed point (0x02/0x03 || X)
//   ECDSA:     X.509 SubjectPublicKeyInfo (DER), curve is whatever the peer
//              chose at keygen time. go-libp2p's default and bee's libp2p
//              identity use the NIST P-256 curve (a.k.a. secp256r1 /
//              prime256v1 / OID 1.2.840.10045.3.1.7).
//
// We support verifying signatures by ECDSA-P256 peers (since bee uses that)
// and Secp256k1 peers (most other libp2p nodes). RSA and Ed25519 are not
// implemented yet — they will return error.UnsupportedKeyType.

const std = @import("std");
const proto = @import("proto.zig");
const identity = @import("identity.zig");
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const KeyType = enum(u64) {
    rsa = 0,
    ed25519 = 1,
    secp256k1 = 2,
    ecdsa = 3,
};

pub const Error = error{
    UnsupportedKeyType,
    InvalidPublicKey,
    InvalidSignature,
    SignatureVerificationFailed,
};

/// Verifies that `sig` (DER-encoded ECDSA signature) is a valid signature of
/// `msg` under the libp2p public key whose protobuf-encoded `data` field is
/// `pubkey_data`, for the given `key_type`. Returns successfully on a valid
/// signature; any error means "do not trust this peer".
pub fn verifySignature(
    key_type: u64,
    pubkey_data: []const u8,
    msg: []const u8,
    sig: []const u8,
) !void {
    switch (key_type) {
        @intFromEnum(KeyType.secp256k1) => {
            const ok = try identity.verifySignatureDer(pubkey_data, hashSha256(msg), sig);
            if (!ok) return Error.SignatureVerificationFailed;
        },
        @intFromEnum(KeyType.ecdsa) => {
            // Parse SubjectPublicKeyInfo, expect P-256.
            const uncompressed = parseP256SubjectPublicKeyInfo(pubkey_data) catch return Error.InvalidPublicKey;
            const pk = EcdsaP256.PublicKey.fromSec1(&uncompressed) catch return Error.InvalidPublicKey;
            const parsed_sig = EcdsaP256.Signature.fromDer(sig) catch return Error.InvalidSignature;
            parsed_sig.verify(msg, pk) catch return Error.SignatureVerificationFailed;
        },
        else => return Error.UnsupportedKeyType,
    }
}

fn hashSha256(msg: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(msg, &h, .{});
    return h;
}

/// Parses a 91-byte X.509 SubjectPublicKeyInfo for an uncompressed
/// ECDSA-P-256 public key. Returns the 65-byte SEC-1 uncompressed point
/// (0x04 || X || Y).
///
/// The DER structure is fixed for this case:
///   SEQUENCE (0x30 0x59)
///     SEQUENCE (0x30 0x13)
///       OID id-ecPublicKey       1.2.840.10045.2.1 (9 bytes incl tag/len)
///       OID prime256v1 / P-256   1.2.840.10045.3.1.7 (10 bytes)
///     BIT STRING (0x03 0x42 0x00) of 66 bytes:
///       0x04 || X(32) || Y(32)
///
/// We do a strict prefix match rather than implementing a full ASN.1 parser —
/// libp2p only ever emits this exact DER blob for P-256 keys.
const P256_SPKI_PREFIX = [_]u8{
    0x30, 0x59,
    0x30, 0x13,
    0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
    0x03, 0x42, 0x00,
};

pub fn parseP256SubjectPublicKeyInfo(spki: []const u8) ![65]u8 {
    if (spki.len != P256_SPKI_PREFIX.len + 65) return error.InvalidSpki;
    if (!std.mem.eql(u8, spki[0..P256_SPKI_PREFIX.len], &P256_SPKI_PREFIX)) return error.InvalidSpki;
    var out: [65]u8 = undefined;
    @memcpy(&out, spki[P256_SPKI_PREFIX.len..]);
    if (out[0] != 0x04) return error.InvalidSpki;
    return out;
}

test "parseP256SubjectPublicKeyInfo extracts the 65-byte uncompressed point" {
    // Sample bee libp2p key captured from a real handshake.
    const allocator = std.testing.allocator;
    const der = try allocator.alloc(u8, 91);
    defer allocator.free(der);
    _ = try std.fmt.hexToBytes(der, "3059301306072a8648ce3d020106082a8648ce3d030107034200049d64068480e9e0851e646cc09aaf108e4ba5eeceaae30ade57f7d0afb2d499adce52269704ad74bd31753a8c0da341c85177e603faa8bb550d47f82c752d2f2c");
    const sec1 = try parseP256SubjectPublicKeyInfo(der);
    try std.testing.expectEqual(@as(u8, 0x04), sec1[0]);
    // Spot-check that the X coord matches the original DER tail.
    var expected_x: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_x, "9d64068480e9e0851e646cc09aaf108e4ba5eeceaae30ade57f7d0afb2d499ad");
    try std.testing.expectEqualSlices(u8, &expected_x, sec1[1..33]);
    // And the parsed key constructs a valid P-256 PublicKey.
    _ = try EcdsaP256.PublicKey.fromSec1(&sec1);
}

test "parseP256SubjectPublicKeyInfo rejects wrong-length input" {
    const bad = [_]u8{ 0x30, 0x59 };
    try std.testing.expectError(error.InvalidSpki, parseP256SubjectPublicKeyInfo(&bad));
}

test "parseP256SubjectPublicKeyInfo rejects non-uncompressed point" {
    var bad = [_]u8{0} ** 91;
    @memcpy(bad[0..P256_SPKI_PREFIX.len], &P256_SPKI_PREFIX);
    bad[P256_SPKI_PREFIX.len] = 0x02; // compressed indicator, not allowed by SPKI
    try std.testing.expectError(error.InvalidSpki, parseP256SubjectPublicKeyInfo(&bad));
}
