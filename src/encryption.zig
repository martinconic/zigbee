// Bee-compatible chunk encryption (0.5b).
//
// Bee encrypts chunk payloads with a keccak256-based stream cipher in
// counter mode. References to encrypted chunks are 64 bytes (32-byte
// chunk address ‖ 32-byte symmetric key).
//
// The cipher (mirrored exactly from `bee/pkg/encryption/encryption.go`):
//
//   For each 32-byte segment at index i in the plaintext/ciphertext:
//     ctr_bytes  = u32_LE(i + init_ctr)
//     ctr_hash   = keccak256(key ‖ ctr_bytes)
//     seg_key    = keccak256(ctr_hash)               // double-hash
//     out[j]     = in[j] XOR seg_key[j]   for j in 0..len(segment)
//
// XOR cipher → encrypt and decrypt are the same operation (`transform`).
//
// Two segment streams per chunk (matching `pkg/encryption/chunk_encryption.go`):
//
//   * Span (8 bytes):    NewSpanEncryption — init_ctr = ChunkSize/KeyLen = 128
//                                            (counter pool starts after the
//                                             data segments so span and data
//                                             keystreams never overlap).
//   * Data (≤4096):      NewDataEncryption — init_ctr = 0, padding = 4096
//                                            (encrypt operation pads with
//                                             random bytes; decrypt expects
//                                             the full padded length back).
//
// Validated against bee's `TestEncryptDataLengthEqualsPadding` golden vector:
// key=8abf1502…6e49, plaintext=4096 zero bytes, padding=4096, init_ctr=0
// → first 32 bytes of ciphertext = 352187af3a843dec…7044ceec.

const std = @import("std");
const crypto = @import("crypto.zig");

pub const KEY_LEN: usize = 32;
pub const REFERENCE_SIZE: usize = 64; // 32-byte addr ‖ 32-byte key
pub const CHUNK_SIZE: usize = 4096;
pub const SPAN_SIZE: usize = 8;
const SEGMENT_LEN: usize = 32;

/// Span-encryption init counter — bee's `NewSpanEncryption`. Starts the
/// keystream after the data segments to avoid keystream reuse.
pub const SPAN_INIT_CTR: u32 = CHUNK_SIZE / SEGMENT_LEN; // 128

/// In-place XOR transform. Same algorithm for encrypt and decrypt.
/// `init_ctr` is the segment-counter offset (0 for data, 128 for span).
pub fn transform(key: [KEY_LEN]u8, buf: []u8, init_ctr: u32) void {
    var seg_idx: u32 = 0;
    var off: usize = 0;
    while (off < buf.len) : (seg_idx += 1) {
        const remaining = buf.len - off;
        const seg_len = @min(SEGMENT_LEN, remaining);

        var seg_key: [SEGMENT_LEN]u8 = undefined;
        deriveSegmentKey(key, init_ctr + seg_idx, &seg_key);

        var j: usize = 0;
        while (j < seg_len) : (j += 1) {
            buf[off + j] ^= seg_key[j];
        }
        off += seg_len;
    }
}

/// segmentKey = keccak256(keccak256(key ‖ u32_LE(counter)))
fn deriveSegmentKey(key: [KEY_LEN]u8, counter: u32, out: *[SEGMENT_LEN]u8) void {
    var ctr_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &ctr_bytes, counter, .little);

    var concat: [KEY_LEN + 4]u8 = undefined;
    @memcpy(concat[0..KEY_LEN], &key);
    @memcpy(concat[KEY_LEN..], &ctr_bytes);

    var ctr_hash: [SEGMENT_LEN]u8 = undefined;
    crypto.keccak256(&concat, &ctr_hash);
    crypto.keccak256(&ctr_hash, out);
}

/// Decrypt a wire-format encrypted chunk: `enc_span(8) ‖ enc_data(≤4096)`.
/// Returns an allocator-owned buffer in the SAME shape as the unencrypted
/// chunk-tree expects: `decrypted_span(8 LE) ‖ decrypted_payload`. The
/// returned `payload` length is trimmed to `decrypted_span` for leaf
/// chunks and to the appropriate ref-list length for intermediate chunks.
///
/// Caller frees the returned slice.
pub fn decryptChunk(
    allocator: std.mem.Allocator,
    key: [KEY_LEN]u8,
    encrypted_chunk: []const u8,
) ![]u8 {
    if (encrypted_chunk.len < SPAN_SIZE) return error.InvalidEncryptedChunk;

    // Decrypt span (8 bytes, init_ctr=128).
    var span_buf: [SPAN_SIZE]u8 = undefined;
    @memcpy(&span_buf, encrypted_chunk[0..SPAN_SIZE]);
    transform(key, &span_buf, SPAN_INIT_CTR);
    const decrypted_span = std.mem.readInt(u64, &span_buf, .little);

    // Decrypt data (init_ctr=0). The encrypted-data field is always padded
    // to CHUNK_SIZE on the wire; we decrypt the whole thing and then trim.
    const enc_data = encrypted_chunk[SPAN_SIZE..];
    const data_buf = try allocator.alloc(u8, enc_data.len);
    errdefer allocator.free(data_buf);
    @memcpy(data_buf, enc_data);
    transform(key, data_buf, 0);

    // Trim:
    //   leaf chunk      (span ≤ CHUNK_SIZE): payload[0..span] is the file data.
    //   intermediate    (span > CHUNK_SIZE): payload is concatenated 64-byte
    //                                        refs. Number of refs = ceil per the
    //                                        encrypted branching factor (64).
    //                                        We compute it from the span tree
    //                                        depth.
    var payload_len: usize = undefined;
    if (decrypted_span <= CHUNK_SIZE) {
        if (decrypted_span > data_buf.len) return error.InvalidEncryptedChunk;
        payload_len = @intCast(decrypted_span);
    } else {
        // Encrypted-tree branching: each intermediate chunk holds up to
        // CHUNK_SIZE / REFERENCE_SIZE = 64 children. At depth d above the
        // leaves, each child covers up to CHUNK_SIZE * 64^d bytes. Number
        // of refs in this node = ceil(span / per_child_max).
        const ref_count = encryptedRefCount(decrypted_span);
        payload_len = ref_count * REFERENCE_SIZE;
        if (payload_len > data_buf.len) return error.InvalidEncryptedChunk;
    }

    const out = try allocator.alloc(u8, SPAN_SIZE + payload_len);
    errdefer allocator.free(out);
    std.mem.writeInt(u64, out[0..SPAN_SIZE], decrypted_span, .little);
    @memcpy(out[SPAN_SIZE .. SPAN_SIZE + payload_len], data_buf[0..payload_len]);

    allocator.free(data_buf);
    return out;
}

/// For an intermediate encrypted chunk whose subtree spans `span` bytes,
/// return the number of 64-byte child references it holds.
///
/// Bee's encrypted chunk-trees use branching factor 64 (CHUNK_SIZE /
/// REFERENCE_SIZE). At depth d above the leaves, each child covers up to
/// CHUNK_SIZE * 64^d bytes. The current node sits one level above its
/// children; its child capacity is CHUNK_SIZE * 64^(d-1) bytes per child,
/// where d is the depth of *this* node above the leaves.
///
/// Algorithm: find the largest power `p = CHUNK_SIZE * 64^k` such that
/// p < span (so this node is *not* a leaf for this range), then the child
/// capacity is `p` bytes and the refcount is `ceil(span / p)`.
fn encryptedRefCount(span: u64) usize {
    const branching: u64 = CHUNK_SIZE / REFERENCE_SIZE; // 64
    var per_child: u64 = CHUNK_SIZE;
    while (per_child * branching < span) per_child *= branching;
    return @intCast((span + per_child - 1) / per_child);
}

// ----------------------------- tests -----------------------------

const testing = std.testing;

test "encryption: bee golden vector — 4096 zero bytes, key 8abf1502..." {
    // From bee/pkg/encryption/encryption_test.go,
    // TestEncryptDataLengthEqualsPadding. Confirms that our keccak256-CTR
    // matches bee's wire cipher byte-for-byte.
    const key_hex = "8abf1502f557f15026716030fb6384792583daf39608a3cd02ff2f47e9bc6e49";
    var key: [KEY_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, key_hex);

    var buf = [_]u8{0} ** 4096;
    transform(key, &buf, 0);

    // First 32-byte segment of the expected ciphertext.
    const expected_seg0_hex = "352187af3a843decc63ceca6cb01ea39dbcf77caf0a8f705f5c30d557044ceec";
    var expected_seg0: [SEGMENT_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_seg0, expected_seg0_hex);
    try testing.expectEqualSlices(u8, &expected_seg0, buf[0..SEGMENT_LEN]);

    // Spot-check the second segment too.
    const expected_seg1_hex = "9392b94a79376f1e5c10cd0c0f2a98e5353bf22b3ea4fdac6677ee553dec192e";
    var expected_seg1: [SEGMENT_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_seg1, expected_seg1_hex);
    try testing.expectEqualSlices(u8, &expected_seg1, buf[SEGMENT_LEN..][0..SEGMENT_LEN]);

    // Third — proves the counter is incrementing correctly.
    const expected_seg2_hex = "3db64e179d0474e96088fb4abd2babd67de123fb398bdf84d818f7bda2c1ab60";
    var expected_seg2: [SEGMENT_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_seg2, expected_seg2_hex);
    try testing.expectEqualSlices(u8, &expected_seg2, buf[2 * SEGMENT_LEN ..][0..SEGMENT_LEN]);
}

test "encryption: transform is involutive (encrypt+decrypt = identity)" {
    var key: [KEY_LEN]u8 = undefined;
    @memset(&key, 0x42);

    var data = [_]u8{0} ** 200;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var copy: [200]u8 = undefined;
    @memcpy(&copy, &data);

    transform(key, &data, 0);
    try testing.expect(!std.mem.eql(u8, &data, &copy)); // changed
    transform(key, &data, 0);
    try testing.expectEqualSlices(u8, &copy, &data); // back to original
}

test "encryption: span and data streams are independent (different init_ctrs)" {
    // The whole reason for SPAN_INIT_CTR=128 is so the span keystream and
    // the data keystream don't overlap. Verify that segment 0 of init_ctr=0
    // differs from segment 0 of init_ctr=128.
    var key: [KEY_LEN]u8 = undefined;
    @memset(&key, 0x37);

    var buf_data = [_]u8{0} ** SEGMENT_LEN;
    transform(key, &buf_data, 0);

    var buf_span = [_]u8{0} ** SEGMENT_LEN;
    transform(key, &buf_span, SPAN_INIT_CTR);

    try testing.expect(!std.mem.eql(u8, &buf_data, &buf_span));
}

test "encryption: decryptChunk round-trip (leaf, span <= CHUNK_SIZE)" {
    var key: [KEY_LEN]u8 = undefined;
    @memset(&key, 0xAA);

    const file_payload = "hello encrypted swarm";
    // Build the wire chunk:
    //   span_le_u64(file_payload.len) ‖ file_payload ‖ random_padding_to_4096
    var wire = [_]u8{0} ** (SPAN_SIZE + CHUNK_SIZE);
    std.mem.writeInt(u64, wire[0..SPAN_SIZE], file_payload.len, .little);
    @memcpy(wire[SPAN_SIZE..][0..file_payload.len], file_payload);

    // Encrypt span and data in place using the same `transform` (it's symmetric).
    transform(key, wire[0..SPAN_SIZE], SPAN_INIT_CTR);
    transform(key, wire[SPAN_SIZE..], 0);

    // Now decrypt.
    const decrypted = try decryptChunk(testing.allocator, key, &wire);
    defer testing.allocator.free(decrypted);

    const span = std.mem.readInt(u64, decrypted[0..SPAN_SIZE], .little);
    try testing.expectEqual(@as(u64, file_payload.len), span);
    try testing.expectEqualStrings(file_payload, decrypted[SPAN_SIZE..]);
}

test "encryption: encryptedRefCount matches branching for various spans" {
    // span just above one chunk → root intermediate with 2 leaf children
    // (one full 4096B leaf, one tiny one).
    try testing.expectEqual(@as(usize, 2), encryptedRefCount(CHUNK_SIZE + 1));
    try testing.expectEqual(@as(usize, 2), encryptedRefCount(CHUNK_SIZE * 2));
    // 64 leaves: the maximum that fits in one intermediate at the smallest
    // depth (branching = 4096/64 = 64).
    try testing.expectEqual(@as(usize, 64), encryptedRefCount(CHUNK_SIZE * 64));
    // 65 leaves doesn't fit in one intermediate; the root goes one level
    // deeper. It has 2 children: one full 64-leaf subtree (262144 bytes),
    // one single-leaf subtree.
    try testing.expectEqual(@as(usize, 2), encryptedRefCount(CHUNK_SIZE * 65));
}
