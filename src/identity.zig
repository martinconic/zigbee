const std = @import("std");
const crypto = @import("crypto.zig");

pub const secp = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_recovery.h");
});

pub const ETHEREUM_ADDRESS_SIZE: usize = 20;
pub const OVERLAY_ADDRESS_SIZE: usize = 32;
pub const COMPRESSED_PUBKEY_SIZE: usize = 33;
/// Maximum length of a DER-encoded ECDSA signature (secp256k1).
pub const ECDSA_DER_MAX_SIZE: usize = 72;

pub const Identity = struct {
    private_key: [32]u8,
    public_key: [65]u8, // Uncompressed: 0x04 || X || Y

    /// Generates a new random identity
    pub fn generate() !Identity {
        const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_NONE) orelse return error.SecpContextCreationFailed;
        defer secp.secp256k1_context_destroy(ctx);

        var private_key: [32]u8 = undefined;
        var pubkey_internal: secp.secp256k1_pubkey = undefined;

        // Generate a valid private key
        while (true) {
            std.crypto.random.bytes(&private_key);
            if (secp.secp256k1_ec_seckey_verify(ctx, &private_key) == 1) {
                break;
            }
        }

        // Derive public key
        if (secp.secp256k1_ec_pubkey_create(ctx, &pubkey_internal, &private_key) != 1) {
            return error.SecpPubkeyCreationFailed;
        }

        // Serialize the public key to uncompressed format
        var pubkey_serialized: [65]u8 = undefined;
        var output_len: usize = 65;
        _ = secp.secp256k1_ec_pubkey_serialize(ctx, &pubkey_serialized, &output_len, &pubkey_internal, secp.SECP256K1_EC_UNCOMPRESSED);

        return Identity{
            .private_key = private_key,
            .public_key = pubkey_serialized,
        };
    }

    /// Ethereum address: last 20 bytes of keccak256(pubkey[1..65]).
    /// The 0x04 prefix of the uncompressed key is stripped before hashing.
    pub fn ethereumAddress(self: *const Identity, out: *[ETHEREUM_ADDRESS_SIZE]u8) void {
        var h: [32]u8 = undefined;
        crypto.keccak256(self.public_key[1..65], &h);
        @memcpy(out, h[12..32]);
    }

    /// 33-byte compressed secp256k1 public key (0x02/0x03 || X).
    /// This is the encoding required by libp2p key_type=3 (Secp256k1).
    pub fn compressedPublicKey(self: *const Identity, out: *[COMPRESSED_PUBKEY_SIZE]u8) !void {
        const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_NONE) orelse return error.SecpContextCreationFailed;
        defer secp.secp256k1_context_destroy(ctx);

        var parsed: secp.secp256k1_pubkey = undefined;
        if (secp.secp256k1_ec_pubkey_parse(ctx, &parsed, &self.public_key, self.public_key.len) != 1) {
            return error.InvalidPublicKey;
        }

        var output_len: usize = COMPRESSED_PUBKEY_SIZE;
        if (secp.secp256k1_ec_pubkey_serialize(ctx, out, &output_len, &parsed, secp.SECP256K1_EC_COMPRESSED) != 1) {
            return error.PubkeySerializationFailed;
        }
        if (output_len != COMPRESSED_PUBKEY_SIZE) return error.PubkeySerializationFailed;
    }

    /// Swarm overlay address:
    ///   keccak256(eth_addr_20 || networkID_le_u64 || nonce_32)
    pub fn overlayAddress(
        self: *const Identity,
        network_id: u64,
        nonce: [32]u8,
        out: *[OVERLAY_ADDRESS_SIZE]u8,
    ) void {
        var eth: [ETHEREUM_ADDRESS_SIZE]u8 = undefined;
        self.ethereumAddress(&eth);
        overlayFromEthereumAddress(eth, network_id, nonce, out);
    }
};

/// Standalone variant matching bee's NewOverlayFromEthereumAddress.
pub fn overlayFromEthereumAddress(
    eth_addr: [ETHEREUM_ADDRESS_SIZE]u8,
    network_id: u64,
    nonce: [32]u8,
    out: *[OVERLAY_ADDRESS_SIZE]u8,
) void {
    var buf: [ETHEREUM_ADDRESS_SIZE + 8 + 32]u8 = undefined;
    @memcpy(buf[0..ETHEREUM_ADDRESS_SIZE], &eth_addr);
    std.mem.writeInt(u64, buf[ETHEREUM_ADDRESS_SIZE..][0..8], network_id, .little);
    @memcpy(buf[ETHEREUM_ADDRESS_SIZE + 8 .. ETHEREUM_ADDRESS_SIZE + 8 + 32], &nonce);
    crypto.keccak256(&buf, out);
}

test "identity generation" {
    const id = try Identity.generate();
    try std.testing.expectEqual(@as(u8, 0x04), id.public_key[0]);

    var overlay: [32]u8 = undefined;
    const nonce: [32]u8 = [_]u8{0} ** 32;
    id.overlayAddress(1, nonce, &overlay);
}

test "overlay from ethereum address - bee golden vectors" {
    // All vectors taken from bee/pkg/crypto/crypto_test.go TestNewOverlayFromEthereumAddress.
    const cases = [_]struct {
        eth_hex: []const u8,
        network_id: u64,
        nonce_hex: []const u8,
        want_hex: []const u8,
    }{
        .{
            .eth_hex = "1815cac638d1525b47f848daf02b7953e4edd15c",
            .network_id = 1,
            .nonce_hex = "0000000000000000000000000000000000000000000000000000000000000001",
            .want_hex = "a38f7a814d4b249ae9d3821e9b898019c78ac9abe248fff171782c32a3849a17",
        },
        .{
            .eth_hex = "1815cac638d1525b47f848daf02b7953e4edd15c",
            .network_id = 1,
            .nonce_hex = "0000000000000000000000000000000000000000000000000000000000000002",
            .want_hex = "c63c10b1728dfc463c64c264f71a621fe640196979375840be42dc496b702610",
        },
        .{
            .eth_hex = "d26bc1715e933bd5f8fad16310042f13abc16159",
            .network_id = 2,
            .nonce_hex = "0000000000000000000000000000000000000000000000000000000000000001",
            .want_hex = "9f421f9149b8e31e238cfbdc6e5e833bacf1e42f77f60874d49291292858968e",
        },
        .{
            .eth_hex = "ac485e3c63dcf9b4cda9f007628bb0b6fed1c063",
            .network_id = 1,
            .nonce_hex = "0000000000000000000000000000000000000000000000000000000000000000",
            .want_hex = "fe3a6d582c577404fb19df64a44e00d3a3b71230a8464c0dd34af3f0791b45f2",
        },
    };

    for (cases) |c| {
        var eth: [ETHEREUM_ADDRESS_SIZE]u8 = undefined;
        _ = try std.fmt.hexToBytes(&eth, c.eth_hex);
        var nonce: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&nonce, c.nonce_hex);
        var want: [OVERLAY_ADDRESS_SIZE]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, c.want_hex);

        var got: [OVERLAY_ADDRESS_SIZE]u8 = undefined;
        overlayFromEthereumAddress(eth, c.network_id, nonce, &got);
        try std.testing.expectEqualSlices(u8, &want, &got);
    }
}

/// Verifies a secp256k1 ECDSA signature
/// pub_key_bytes: The compressed or uncompressed secp256k1 public key
/// hash: The 32-byte hash of the message that was signed
/// sig: The 64-byte signature (R, S)
pub fn verifySignature(pub_key_bytes: []const u8, hash: [32]u8, sig: []const u8) !bool {
    if (sig.len < 64) return error.InvalidSignatureLength;

    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_VERIFY) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var parsed_pubkey: secp.secp256k1_pubkey = undefined;
    if (secp.secp256k1_ec_pubkey_parse(ctx, &parsed_pubkey, pub_key_bytes.ptr, pub_key_bytes.len) != 1) {
        return error.InvalidPublicKey;
    }

    var parsed_sig: secp.secp256k1_ecdsa_signature = undefined;
    // libp2p signatures are 64 bytes (compact R, S)
    if (secp.secp256k1_ecdsa_signature_parse_compact(ctx, &parsed_sig, sig.ptr) != 1) {
        return error.InvalidSignatureFormat;
    }

    // Verify signature
    const result = secp.secp256k1_ecdsa_verify(ctx, &parsed_sig, &hash, &parsed_pubkey);
    return result == 1;
}

/// Signs a 32-byte hash using the private key and outputs a 64-byte compact signature
pub fn signCompact(private_key: [32]u8, hash: [32]u8, sig_out: *[64]u8) !void {
    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_SIGN) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var sig: secp.secp256k1_ecdsa_signature = undefined;
    if (secp.secp256k1_ecdsa_sign(ctx, &sig, &hash, &private_key, null, null) != 1) {
        return error.SignatureGenerationFailed;
    }

    if (secp.secp256k1_ecdsa_signature_serialize_compact(ctx, sig_out, &sig) != 1) {
        return error.SignatureSerializationFailed;
    }
}

/// Signs a 32-byte hash and writes a DER-encoded signature into `sig_out`.
/// Returns the actual length written (DER signatures are variable, max 72 bytes).
/// libp2p Secp256k1 mandates DER-encoded signatures.
pub fn signDer(private_key: [32]u8, hash: [32]u8, sig_out: *[ECDSA_DER_MAX_SIZE]u8) !usize {
    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_SIGN) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var sig: secp.secp256k1_ecdsa_signature = undefined;
    if (secp.secp256k1_ecdsa_sign(ctx, &sig, &hash, &private_key, null, null) != 1) {
        return error.SignatureGenerationFailed;
    }

    var output_len: usize = ECDSA_DER_MAX_SIZE;
    if (secp.secp256k1_ecdsa_signature_serialize_der(ctx, sig_out, &output_len, &sig) != 1) {
        return error.SignatureSerializationFailed;
    }
    return output_len;
}

/// Signs `data` Ethereum-style: applies the EIP-191 personal-message prefix,
/// hashes with Keccak-256, signs with secp256k1, returns a 65-byte signature
/// formatted as r (32 BE) || s (32 BE) || v where v ∈ {27, 28}. This is the
/// format `bee/pkg/crypto.Signer.Sign` produces and that bee's
/// `crypto.Recover` expects on the wire.
pub fn signEthereum(private_key: [32]u8, data: []const u8, sig_out: *[65]u8) !void {
    // EIP-191: "\x19Ethereum Signed Message:\n" || decimal(len(data)) || data
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "\x19Ethereum Signed Message:\n{d}", .{data.len});

    // Hash the prefix + payload in one Keccak256 pass.
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(data);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_SIGN) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var rsig: secp.secp256k1_ecdsa_recoverable_signature = undefined;
    if (secp.secp256k1_ecdsa_sign_recoverable(ctx, &rsig, &hash, &private_key, null, null) != 1) {
        return error.SignatureGenerationFailed;
    }

    var rs: [64]u8 = undefined;
    var recid: c_int = 0;
    if (secp.secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &rs, &recid, &rsig) != 1) {
        return error.SignatureSerializationFailed;
    }

    @memcpy(sig_out[0..64], &rs);
    sig_out[64] = @intCast(27 + recid);
}

/// Recovers the secp256k1 public key (33-byte SEC-1 compressed) that produced
/// `sig` (r||s||v, 65 bytes) over the EIP-191-prefixed `data`. Used to verify
/// peers' bzz-handshake addresses.
pub fn recoverEthereum(data: []const u8, sig: [65]u8, pubkey_out: *[33]u8) !void {
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "\x19Ethereum Signed Message:\n{d}", .{data.len});

    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(data);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    if (sig[64] < 27 or sig[64] > 30) return error.InvalidSignatureFormat;
    const recid: c_int = @intCast(sig[64] - 27);

    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_VERIFY) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var rsig: secp.secp256k1_ecdsa_recoverable_signature = undefined;
    var rs: [64]u8 = undefined;
    @memcpy(&rs, sig[0..64]);
    if (secp.secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &rsig, &rs, recid) != 1) {
        return error.InvalidSignatureFormat;
    }

    var pubkey: secp.secp256k1_pubkey = undefined;
    if (secp.secp256k1_ecdsa_recover(ctx, &pubkey, &rsig, &hash) != 1) {
        return error.SignatureVerificationFailed;
    }

    var out_len: usize = 33;
    if (secp.secp256k1_ec_pubkey_serialize(ctx, pubkey_out, &out_len, &pubkey, secp.SECP256K1_EC_COMPRESSED) != 1) {
        return error.PubkeySerializationFailed;
    }
    if (out_len != 33) return error.PubkeySerializationFailed;
}

test "signEthereum + recoverEthereum round-trip" {
    const id = try Identity.generate();
    const data = "bee-handshake-payload-bytes";
    var sig: [65]u8 = undefined;
    try signEthereum(id.private_key, data, &sig);
    try std.testing.expect(sig[64] == 27 or sig[64] == 28);

    var recovered: [33]u8 = undefined;
    try recoverEthereum(data, sig, &recovered);

    var compressed_self: [33]u8 = undefined;
    try id.compressedPublicKey(&compressed_self);
    try std.testing.expectEqualSlices(u8, &compressed_self, &recovered);
}

/// Verifies a DER-encoded ECDSA signature.
pub fn verifySignatureDer(pub_key_bytes: []const u8, hash: [32]u8, sig_der: []const u8) !bool {
    const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_VERIFY) orelse return error.SecpContextCreationFailed;
    defer secp.secp256k1_context_destroy(ctx);

    var parsed_pubkey: secp.secp256k1_pubkey = undefined;
    if (secp.secp256k1_ec_pubkey_parse(ctx, &parsed_pubkey, pub_key_bytes.ptr, pub_key_bytes.len) != 1) {
        return error.InvalidPublicKey;
    }

    var parsed_sig: secp.secp256k1_ecdsa_signature = undefined;
    if (secp.secp256k1_ecdsa_signature_parse_der(ctx, &parsed_sig, sig_der.ptr, sig_der.len) != 1) {
        return error.InvalidSignatureFormat;
    }

    return secp.secp256k1_ecdsa_verify(ctx, &parsed_sig, &hash, &parsed_pubkey) == 1;
}

test "compressed pubkey + DER sign/verify roundtrip" {
    const id = try Identity.generate();

    var compressed: [COMPRESSED_PUBKEY_SIZE]u8 = undefined;
    try id.compressedPublicKey(&compressed);
    try std.testing.expect(compressed[0] == 0x02 or compressed[0] == 0x03);

    var hash: [32]u8 = undefined;
    crypto.keccak256("noise-libp2p-static-key:test-payload", &hash);

    var sig_buf: [ECDSA_DER_MAX_SIZE]u8 = undefined;
    const sig_len = try signDer(id.private_key, hash, &sig_buf);
    try std.testing.expect(sig_len > 0 and sig_len <= ECDSA_DER_MAX_SIZE);

    // Verify against the compressed pubkey (libp2p Secp256k1 wire format).
    try std.testing.expect(try verifySignatureDer(&compressed, hash, sig_buf[0..sig_len]));

    // And against the uncompressed pubkey — secp256k1_ec_pubkey_parse accepts both.
    try std.testing.expect(try verifySignatureDer(&id.public_key, hash, sig_buf[0..sig_len]));

    // A flipped bit in the hash must fail.
    var bad_hash = hash;
    bad_hash[0] ^= 0xff;
    try std.testing.expect(!(try verifySignatureDer(&compressed, bad_hash, sig_buf[0..sig_len])));
}
