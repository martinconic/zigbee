// Single-Owner Chunks (SOCs).
//
// A SOC has chunk address `keccak256(id ‖ owner_eth_address)` rather
// than the BMT-derived address used by content-addressed chunks (CACs).
// Used by Swarm feeds (the owner publishes a stream of updates at a
// stable address) and a handful of internal constructs (replica chunks,
// postage stamp issuance state).
//
// Wire layout — the bytes carried in retrieval `Delivery.Data` when the
// caller asked for a SOC address (i.e., what `swarm.Chunk.Data()` returns
// for a SOC in Go bee):
//
//   id        : 32 bytes
//   signature : 65 bytes (r ‖ s ‖ v with v ∈ {27,28[,29,30]})
//   span      :  8 bytes (little-endian uint64 — same span as the inner CAC)
//   payload   : up to 4096 bytes
//
// Validation:
//   1. inner_addr   = bmt(span ‖ payload)              — same hash as CAC
//   2. to_sign      = keccak256(id ‖ inner_addr)       — 32-byte intermediate
//   3. eip191_msg   = "\x19Ethereum Signed Message:\n32" ‖ to_sign
//   4. signed_digest = keccak256(eip191_msg)
//   5. owner        = ecrecover(sig, signed_digest)    — 20-byte eth addr
//   6. derived      = keccak256(id ‖ owner)
//   7. derived must equal the address the caller asked for.
//
// Step 3 is non-obvious: bee passes `to_sign` as the *data* argument
// to `crypto.Sign` / `crypto.Recover`, both of which transparently
// apply EIP-191 prefixing before hashing. So even though SOC isn't
// an Ethereum-message signature in spirit, the on-the-wire signature
// is over the EIP-191-prefixed digest.
//
// References: bee/pkg/soc/soc.go (FromChunk); bee/pkg/crypto/signer.go
// (hashWithEthereumPrefix in `Recover`).

const std = @import("std");
const crypto = @import("crypto.zig");
const bmt = @import("bmt.zig");
const identity = @import("identity.zig");

pub const ID_SIZE: usize = 32;
pub const SIGNATURE_SIZE: usize = 65;
/// id + signature, before the inner CAC (span+payload).
pub const HEADER_SIZE: usize = ID_SIZE + SIGNATURE_SIZE; // 97
/// Smallest valid SOC chunk: header + span (empty payload).
pub const MIN_CHUNK_SIZE: usize = HEADER_SIZE + bmt.SPAN_SIZE; // 105
pub const ADDRESS_SIZE: usize = bmt.HASH_SIZE; // 32

pub const Error = error{
    SocChunkTooSmall,
    SocPayloadTooLarge,
    InvalidSignatureFormat,
    SignatureRecoveryFailed,
    AddressMismatch,
};

pub const Soc = struct {
    id: [ID_SIZE]u8,
    signature: [SIGNATURE_SIZE]u8,
    span: u64,
    /// Aliases into the input bytes — NOT allocator-owned. Caller must
    /// keep the source slice alive for as long as `payload` is in use.
    payload: []const u8,
    owner: [identity.ETHEREUM_ADDRESS_SIZE]u8,
};

/// Compute a SOC address from the (id, owner) pair: `keccak256(id ‖ owner)`.
pub fn createAddress(
    id: [ID_SIZE]u8,
    owner: [identity.ETHEREUM_ADDRESS_SIZE]u8,
    out: *[ADDRESS_SIZE]u8,
) void {
    var buf: [ID_SIZE + identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
    @memcpy(buf[0..ID_SIZE], &id);
    @memcpy(buf[ID_SIZE..], &owner);
    crypto.keccak256(&buf, out);
}

/// Parse and validate a raw SOC `chunk_data` blob (the bytes a retrieval
/// `Delivery.Data` field carries when the requested address is a SOC):
/// `id(32) ‖ sig(65) ‖ span(8) ‖ payload(≤4096)`.
///
/// Errors if the layout is malformed, the signature doesn't recover, or
/// the recovered owner's derived SOC address doesn't match `expected`.
pub fn parseAndValidate(
    chunk_data: []const u8,
    expected: [ADDRESS_SIZE]u8,
) Error!Soc {
    if (chunk_data.len < MIN_CHUNK_SIZE) return Error.SocChunkTooSmall;
    const payload_len = chunk_data.len - HEADER_SIZE - bmt.SPAN_SIZE;
    if (payload_len > bmt.CHUNK_SIZE) return Error.SocPayloadTooLarge;

    var soc: Soc = undefined;
    @memcpy(&soc.id, chunk_data[0..ID_SIZE]);
    @memcpy(&soc.signature, chunk_data[ID_SIZE..HEADER_SIZE]);
    soc.span = std.mem.readInt(u64, chunk_data[HEADER_SIZE..][0..bmt.SPAN_SIZE], .little);
    soc.payload = chunk_data[HEADER_SIZE + bmt.SPAN_SIZE ..];

    // 1. inner CAC address — BMT root over payload zero-padded to 4096,
    //    keccak256-prefixed with span.
    var inner = bmt.Chunk.init(soc.payload);
    inner.span = soc.span;
    var inner_addr: [bmt.HASH_SIZE]u8 = undefined;
    inner.address(&inner_addr) catch return Error.SocPayloadTooLarge;

    // 2. to_sign = keccak256(id ‖ inner_addr) — the bytes bee passes as
    //    `data` to its EIP-191-prefixing signer. We mirror that here:
    //    the actual signed digest is keccak256(eip191_prefix ‖ to_sign).
    var to_sign_buf: [ID_SIZE + bmt.HASH_SIZE]u8 = undefined;
    @memcpy(to_sign_buf[0..ID_SIZE], &soc.id);
    @memcpy(to_sign_buf[ID_SIZE..], &inner_addr);
    var to_sign: [32]u8 = undefined;
    crypto.keccak256(&to_sign_buf, &to_sign);

    // 3. recover owner eth addr from sig over the EIP-191-prefixed digest.
    identity.recoverEthAddrEip191(&to_sign, soc.signature, &soc.owner) catch
        return Error.SignatureRecoveryFailed;

    // 4. derived = keccak256(id ‖ owner) must equal expected.
    var derived: [ADDRESS_SIZE]u8 = undefined;
    createAddress(soc.id, soc.owner, &derived);
    if (!std.mem.eql(u8, &derived, &expected)) return Error.AddressMismatch;

    return soc;
}

// --- tests --------------------------------------------------------------

test "SOC golden vector — bee TestNewSigned/TestChunk" {
    // payload = "foo"; id = 32 zero bytes; owner = 8d3766...e632.
    // sig recovers to that owner; expected SOC address = keccak256(id ‖ owner).
    // Source: ethersphere/bee pkg/soc/soc_test.go.
    const id = [_]u8{0} ** 32;
    var owner: [identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(&owner, "8d3766440f0d7b949a5e32995d09619a7f86e632");
    var sig: [SIGNATURE_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &sig,
        "5acd384febc133b7b245e5ddc62d82d2cded9182d2716126cd8844509af65a05" ++
            "3deb418208027f548e3e88343af6f84a8772fb3cebc0a1833a0ea7ec0c134831" ++
            "1b",
    );

    const payload = "foo";
    var blob: [MIN_CHUNK_SIZE + 3]u8 = undefined;
    @memcpy(blob[0..ID_SIZE], &id);
    @memcpy(blob[ID_SIZE..HEADER_SIZE], &sig);
    std.mem.writeInt(u64, blob[HEADER_SIZE..][0..bmt.SPAN_SIZE], payload.len, .little);
    @memcpy(blob[MIN_CHUNK_SIZE..], payload);

    var expected: [ADDRESS_SIZE]u8 = undefined;
    createAddress(id, owner, &expected);

    const s = try parseAndValidate(&blob, expected);
    try std.testing.expectEqualSlices(u8, &owner, &s.owner);
    try std.testing.expectEqualSlices(u8, payload, s.payload);
    try std.testing.expectEqual(@as(u64, payload.len), s.span);
    try std.testing.expectEqualSlices(u8, &id, &s.id);
}

test "SOC parse rejects undersized chunk" {
    const blob: [50]u8 = [_]u8{0} ** 50;
    var expected: [ADDRESS_SIZE]u8 = undefined;
    @memset(&expected, 0);
    try std.testing.expectError(Error.SocChunkTooSmall, parseAndValidate(&blob, expected));
}

test "SOC parse rejects address mismatch" {
    // Same setup as the golden vector but pass a wrong expected address:
    // the signature will recover to the real owner, but the derived
    // keccak256(id ‖ owner) won't match `wrong`, so we get AddressMismatch.
    const id = [_]u8{0} ** 32;
    var sig: [SIGNATURE_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &sig,
        "5acd384febc133b7b245e5ddc62d82d2cded9182d2716126cd8844509af65a05" ++
            "3deb418208027f548e3e88343af6f84a8772fb3cebc0a1833a0ea7ec0c134831" ++
            "1b",
    );

    const payload = "foo";
    var blob: [MIN_CHUNK_SIZE + 3]u8 = undefined;
    @memcpy(blob[0..ID_SIZE], &id);
    @memcpy(blob[ID_SIZE..HEADER_SIZE], &sig);
    std.mem.writeInt(u64, blob[HEADER_SIZE..][0..bmt.SPAN_SIZE], payload.len, .little);
    @memcpy(blob[MIN_CHUNK_SIZE..], payload);

    var wrong: [ADDRESS_SIZE]u8 = undefined;
    @memset(&wrong, 0xAA);
    try std.testing.expectError(Error.AddressMismatch, parseAndValidate(&blob, wrong));
}

test "SOC parse rejects invalid signature v byte" {
    const id = [_]u8{0} ** 32;
    var sig: [SIGNATURE_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &sig,
        "5acd384febc133b7b245e5ddc62d82d2cded9182d2716126cd8844509af65a05" ++
            "3deb418208027f548e3e88343af6f84a8772fb3cebc0a1833a0ea7ec0c134831" ++
            "1b",
    );
    sig[64] = 0; // out-of-range recovery id

    const payload = "foo";
    var blob: [MIN_CHUNK_SIZE + 3]u8 = undefined;
    @memcpy(blob[0..ID_SIZE], &id);
    @memcpy(blob[ID_SIZE..HEADER_SIZE], &sig);
    std.mem.writeInt(u64, blob[HEADER_SIZE..][0..bmt.SPAN_SIZE], payload.len, .little);
    @memcpy(blob[MIN_CHUNK_SIZE..], payload);

    var expected: [ADDRESS_SIZE]u8 = undefined;
    @memset(&expected, 0);
    try std.testing.expectError(Error.SignatureRecoveryFailed, parseAndValidate(&blob, expected));
}

test "createAddress matches keccak256(id ‖ owner)" {
    var id: [ID_SIZE]u8 = undefined;
    @memset(&id, 0xAB);
    var owner: [identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(&owner, "8d3766440f0d7b949a5e32995d09619a7f86e632");

    var got: [ADDRESS_SIZE]u8 = undefined;
    createAddress(id, owner, &got);

    var buf: [ID_SIZE + identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
    @memcpy(buf[0..ID_SIZE], &id);
    @memcpy(buf[ID_SIZE..], &owner);
    var expected: [ADDRESS_SIZE]u8 = undefined;
    crypto.keccak256(&buf, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}
