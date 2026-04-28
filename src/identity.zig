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

    /// Build an Identity from an already-known private key. Used by
    /// `loadOrCreate` after reading a key from disk; verifies the
    /// scalar is valid for secp256k1 and recomputes the public key.
    pub fn fromPrivateKey(private_key: [32]u8) !Identity {
        const ctx = secp.secp256k1_context_create(secp.SECP256K1_CONTEXT_NONE) orelse return error.SecpContextCreationFailed;
        defer secp.secp256k1_context_destroy(ctx);

        if (secp.secp256k1_ec_seckey_verify(ctx, &private_key) != 1) {
            return error.InvalidPrivateKey;
        }

        var pubkey_internal: secp.secp256k1_pubkey = undefined;
        if (secp.secp256k1_ec_pubkey_create(ctx, &pubkey_internal, &private_key) != 1) {
            return error.SecpPubkeyCreationFailed;
        }

        var pubkey_serialized: [65]u8 = undefined;
        var output_len: usize = 65;
        _ = secp.secp256k1_ec_pubkey_serialize(ctx, &pubkey_serialized, &output_len, &pubkey_internal, secp.SECP256K1_EC_UNCOMPRESSED);

        return Identity{
            .private_key = private_key,
            .public_key = pubkey_serialized,
        };
    }

    /// Load a persistent identity from `path`, or generate a fresh one
    /// and atomically write it there if the file doesn't exist.
    ///
    /// The file is **64 bytes**: the first 32 are the secp256k1
    /// private key, the next 32 are the bzz overlay nonce. Both must
    /// persist across runs — without the nonce, the overlay changes
    /// every restart even with the same libp2p key, and bee's
    /// per-peer accounting state (which is keyed on overlay) resets.
    /// Persisting the libp2p key alone gives no user-visible benefit.
    ///
    /// Atomic-write semantics for IoT durability (cross-cutting item
    /// X2): tempfile → fsync → rename. A power loss mid-write leaves
    /// the old file or the new one, never a partial / corrupt key.
    ///
    /// Returns the Identity. The 32-byte nonce is returned via the
    /// out-parameter `nonce_out`.
    pub fn loadOrCreate(
        allocator: std.mem.Allocator,
        path: []const u8,
        nonce_out: *[32]u8,
    ) !Identity {
        if (readKeyAndNonce(path)) |kn| {
            @memcpy(nonce_out, &kn.nonce);
            return try fromPrivateKey(kn.key);
        } else |e| switch (e) {
            error.FileNotFound => {}, // fall through to generation
            else => return e,
        }

        // Generate a fresh identity AND a fresh nonce; persist both.
        const id = try Identity.generate();
        std.crypto.random.bytes(nonce_out);
        try writeKeyAndNonceAtomic(allocator, path, id.private_key, nonce_out.*);
        return id;
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

// ---- persistent-identity helpers (file I/O) -------------------------

const KeyAndNonce = struct {
    key: [32]u8,
    nonce: [32]u8,
};

/// Read the 64-byte (key ‖ nonce) blob from `path`. Errors:
///   error.FileNotFound  — file doesn't exist (caller generates fresh)
///   error.InvalidKeyFile — file exists but isn't exactly 64 bytes
fn readKeyAndNonce(path: []const u8) !KeyAndNonce {
    var file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return e,
    };
    defer file.close();

    var buf: [65]u8 = undefined; // 1 byte slack to detect oversize
    const n = try file.readAll(&buf);
    if (n != 64) return error.InvalidKeyFile;

    var out: KeyAndNonce = undefined;
    @memcpy(&out.key, buf[0..32]);
    @memcpy(&out.nonce, buf[32..64]);
    return out;
}

/// Atomically write `key ‖ nonce` (64 bytes) to `path`.
/// Steps: ensure parent dir exists → write tempfile → fsync → rename.
/// A power loss mid-write leaves either the old file (rename hadn't
/// happened) or the new one (rename succeeded) — never partial.
fn writeKeyAndNonceAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    key: [32]u8,
    nonce: [32]u8,
) !void {
    // Ensure the containing directory exists. We don't fight with its
    // mode — file-level 0o600 is what protects the key.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    // Write the temp file (64 bytes: 32-byte key ‖ 32-byte nonce).
    // File mode is whatever your umask permits (typically 0644 or
    // 0664). zigbee can't reliably tighten it via std.posix.fchmod
    // in this Zig version (0.15) — the stdlib treats a few possible
    // syscall returns as `unreachable` on tmpfs / atypical mounts.
    // If you want strict 0600 (e.g. multi-user host), set
    // `umask 0077` before launching, OR
    // `chmod 600 ~/.zigbee/identity.key` after first run.
    {
        var tmp = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer tmp.close();
        try tmp.writeAll(&key);
        try tmp.writeAll(&nonce);
        try tmp.sync();
    }

    // Atomic rename — POSIX guarantees the target is either fully
    // old or fully new, never partial.
    //
    // For belt-and-braces durability we'd also fsync the containing
    // directory so the new dirent metadata survives a power loss
    // immediately after rename, but Zig 0.15's std.posix.fsync
    // treats a directory fd as `unreachable` (BADF/INVAL/ROFS).
    // Modern filesystems (ext4, xfs, btrfs, apfs) flush rename
    // metadata as a side effect, so the missing dir-fsync is at
    // worst a few-ms-of-power-loss exposure on the very-first run.
    // For an identity key — generated once and read forever — the
    // tradeoff is acceptable.
    try std.fs.cwd().rename(tmp_path, path);
}

/// Default identity-file path: `$HOME/.zigbee/identity.key`. Caller
/// owns the returned slice.
pub fn defaultIdentityPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeEnv;
    return try std.fs.path.join(allocator, &.{ home, ".zigbee", "identity.key" });
}

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

test "loadOrCreate: round-trips key + nonce, second call returns the same identity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const key_path = try std.fs.path.join(allocator, &.{ path, "identity.key" });
    defer allocator.free(key_path);

    // First call: file doesn't exist → generates + persists.
    var nonce1: [32]u8 = undefined;
    const id1 = try Identity.loadOrCreate(allocator, key_path, &nonce1);
    // Second call: file exists → loads the same key and nonce.
    var nonce2: [32]u8 = undefined;
    const id2 = try Identity.loadOrCreate(allocator, key_path, &nonce2);

    try std.testing.expectEqualSlices(u8, &id1.private_key, &id2.private_key);
    try std.testing.expectEqualSlices(u8, &id1.public_key, &id2.public_key);
    try std.testing.expectEqualSlices(u8, &nonce1, &nonce2);

    // Sanity: file is exactly 64 bytes (32 key + 32 nonce).
    var f = try std.fs.cwd().openFile(key_path, .{});
    defer f.close();
    const stat = try f.stat();
    try std.testing.expectEqual(@as(u64, 64), stat.size);
}

test "loadOrCreate: rejects malformed key file (wrong size)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const key_path = try std.fs.path.join(allocator, &.{ path, "bad.key" });
    defer allocator.free(key_path);

    // Pre-write a 32-byte file (right size for the OLD format, wrong
    // for the new 64-byte key+nonce format — mainly here to confirm
    // we reject anything that isn't exactly 64 bytes).
    {
        var f = try std.fs.cwd().createFile(key_path, .{});
        defer f.close();
        try f.writeAll(&[_]u8{0xAA} ** 32);
    }

    var nonce: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidKeyFile, Identity.loadOrCreate(allocator, key_path, &nonce));
}

test "fromPrivateKey: rejects all-zero scalar (not on the curve)" {
    const zero: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectError(error.InvalidPrivateKey, Identity.fromPrivateKey(zero));
}

test "fromPrivateKey: round-trips a generated key" {
    const id1 = try Identity.generate();
    const id2 = try Identity.fromPrivateKey(id1.private_key);
    try std.testing.expectEqualSlices(u8, &id1.public_key, &id2.public_key);
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
